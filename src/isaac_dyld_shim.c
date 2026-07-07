/*
 * isaac_dyld_shim.c
 *
 * Compatibility shim that lets The Binding of Isaac: Rebirth / Afterbirth /
 * Afterbirth+ launch on modern macOS (tested on macOS 15 "Sequoia", Apple
 * Silicon via Rosetta 2) instead of instantly segfaulting.
 *
 * ---------------------------------------------------------------------------
 * ROOT CAUSE
 * ---------------------------------------------------------------------------
 * The game ships wrapped in Steam's DRM. At launch, Valve's steamloader.dylib
 * runs CGlobalInitter::CrackMainImage(), which decrypts the real game code and
 * jumps into it. That decrypted code then calls one of steamloader's own
 * ancient dyld-compatibility stubs (e.g. _dyld_func_lookup /
 * _dyld_lookup_and_bind) to resolve a dyld-internal function by name -- the way
 * it was done on Mac OS X ~2006.
 *
 * That stub is a classic lazily-bound "jump through a GOT slot" stub, and on
 * modern macOS its GOT slot is never bound. It still contains the stale
 * build-time placeholder that points at the OLD, FIXED, pre-ASLR dyld shared
 * cache base address (~0x7fff5fc00000). On today's macOS the shared cache is
 * randomized and nothing is mapped there, so the call is an instruction fetch
 * into unmapped memory -> SIGSEGV (EXC_BAD_ACCESS / KERN_INVALID_ADDRESS) at an
 * address like 0x7fff5fc01008. Every launch dies there.
 *
 * This is a bug in Valve's very old, unmaintained DRM loader, not in the game,
 * and it likely affects other old Steam-DRM-wrapped Mac titles too.
 *
 * ---------------------------------------------------------------------------
 * THE FIX
 * ---------------------------------------------------------------------------
 * Install a SIGSEGV/SIGBUS handler. When a fault's instruction pointer lands in
 * that dead legacy address range, treat it as this exact bug: the calling
 * convention is the old bool _dyld_func_lookup(const char *name, void **addr)
 * (name in RDI, out-pointer in RSI). Resolve the requested symbol with dlsym,
 * write it to *addr, then emulate a normal return from the call that faulted
 * (pop the return address the CALL already pushed, restore RSP, set RIP to it,
 * set RAX to success). Execution resumes as if the lookup had worked, and the
 * game continues into normal startup.
 *
 * Any other fault (a different address, an unrelated bug) is passed through to
 * whatever handler was previously installed, so we never mask real crashes.
 *
 * This does NOT touch, patch, decrypt, or bypass any game file or any Valve
 * binary. steamloader.dylib runs in full; we only repair one broken call it
 * makes. Nothing copyrighted is modified or redistributed.
 * ---------------------------------------------------------------------------
 */

#define _XOPEN_SOURCE 1
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <ucontext.h>
#include <dlfcn.h>

/* The classic pre-ASLR dyld shared cache lived around 0x7fff5fc00000 on older
 * macOS. Match any code-fetch fault whose address falls in that general legacy
 * region, rather than one exact byte value, since the specific offset depends
 * on which stub is unbound. */
static int is_legacy_stale_address(uint64_t addr) {
    return addr >= 0x00007fff58000000ULL && addr <= 0x00007fff68000000ULL;
}

static struct sigaction g_prev_segv;
static struct sigaction g_prev_bus;

static void handle_fault(int sig, siginfo_t *info, void *uctxRaw) {
    ucontext_t *uctx = (ucontext_t *)uctxRaw;
    uint64_t rip = uctx->uc_mcontext->__ss.__rip;

    if (!is_legacy_stale_address(rip)) {
        /* Not our bug -- chain to whatever was previously installed. */
        struct sigaction *prev = (sig == SIGSEGV) ? &g_prev_segv : &g_prev_bus;
        if (prev->sa_flags & SA_SIGINFO) {
            if (prev->sa_sigaction) prev->sa_sigaction(sig, info, uctxRaw);
            return;
        } else if (prev->sa_handler == SIG_DFL) {
            signal(sig, SIG_DFL);
            raise(sig);
            return;
        } else if (prev->sa_handler != SIG_IGN && prev->sa_handler) {
            prev->sa_handler(sig);
            return;
        }
        /* No usable previous handler: fall back to default (crash for real). */
        signal(sig, SIG_DFL);
        raise(sig);
        return;
    }

    fprintf(stderr, "[isaac-shim] caught stale legacy-dyld code fetch at 0x%llx -- emulating _dyld_func_lookup\n",
            (unsigned long long)rip);

    uint64_t rdi = uctx->uc_mcontext->__ss.__rdi; /* const char *name */
    uint64_t rsi = uctx->uc_mcontext->__ss.__rsi; /* void **address (out param) */
    uint64_t rsp = uctx->uc_mcontext->__ss.__rsp;

    const char *name = (const char *)rdi;
    void **outAddr = (void **)rsi;

    /* Sanity-check the name pointer looks like a real, short, printable C string
     * before trusting it -- if our address-range heuristic ever misfires, we
     * don't want to dereference garbage. */
    int looks_sane = 0;
    if (name) {
        size_t i;
        for (i = 0; i < 128; i++) {
            char c = name[i];
            if (c == '\0') { looks_sane = 1; break; }
            if (c < 0x20 || c > 0x7e) break;
        }
    }

    void *resolved = NULL;
    if (looks_sane) {
        const char *dlsymName = (name[0] == '_') ? name + 1 : name;
        resolved = dlsym(RTLD_DEFAULT, dlsymName);
        fprintf(stderr, "[isaac-shim] lookup \"%s\" -> %p\n", name, resolved);
    } else {
        fprintf(stderr, "[isaac-shim] name pointer at 0x%llx didn't look sane, treating lookup as failed\n",
                (unsigned long long)rdi);
    }

    if (resolved && outAddr) {
        *outAddr = resolved;
    }

    /* Emulate a normal `ret` from the call that jumped here: the `call`
     * instruction already pushed the return address and decremented rsp before
     * faulting on the instruction fetch at the bad target. Pop it and resume. */
    uint64_t retAddr = *(uint64_t *)rsp;
    uctx->uc_mcontext->__ss.__rip = retAddr;
    uctx->uc_mcontext->__ss.__rsp = rsp + 8;
    uctx->uc_mcontext->__ss.__rax = resolved ? 1 : 0;

    fprintf(stderr, "[isaac-shim] resuming at return address 0x%llx (result=%s)\n",
            (unsigned long long)retAddr, resolved ? "found" : "NOT FOUND");
}

__attribute__((constructor))
static void isaac_shim_install(void) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = handle_fault;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);

    sigaction(SIGSEGV, &sa, &g_prev_segv);
    sigaction(SIGBUS, &sa, &g_prev_bus);

    fprintf(stderr, "[isaac-shim] installed, watching for legacy dyld address faults\n");
}
