#import "PAImageHider.h"

#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/mman.h>
#import <string.h>

// ---------------------------------------------------------------------------
// Which images to hide: our injected file under any past/future filename.
// ---------------------------------------------------------------------------

static BOOL PAIsHiddenPath(const char *path) {
    if (!path) return NO;
    return strstr(path, "BloomKit") != NULL ||
           strstr(path, "PoolAdmin") != NULL;
}

// ---------------------------------------------------------------------------
// Filtered _dyld_* replacements.
// ---------------------------------------------------------------------------

static uint32_t (*sRealCount)(void) = NULL;
static const char *(*sRealName)(uint32_t) = NULL;

static uint32_t PA_image_count(void) {
    if (!sRealCount) return 0;
    const uint32_t total = sRealCount();
    uint32_t hidden = 0;
    for (uint32_t i = 0; i < total; i++) {
        @try {
            if (PAIsHiddenPath(sRealName(i))) hidden++;
        } @catch (NSException *e) {}
    }
    return total - hidden;
}

static const char *PA_image_name(uint32_t index) {
    if (!sRealName) return NULL;
    const uint32_t total = sRealCount ? sRealCount() : 0;
    uint32_t seen = 0;
    for (uint32_t i = 0; i < total; i++) {
        const char *name = NULL;
        @try {
            name = sRealName(i);
        } @catch (NSException *e) {
            continue;
        }
        if (PAIsHiddenPath(name)) continue;
        if (seen == index) return name;
        seen++;
    }
    return NULL;
}

// ---------------------------------------------------------------------------
// Classic (LC_DYLD_INFO) symbol-pointer rebinding, one image at a time.
// Skips images without classic tables (chained-fixups-only) safely.
// ---------------------------------------------------------------------------

static void PARebindPointers(struct mach_header_64 *header,
                             intptr_t slide,
                             const char *targetName,
                             void *replacement) {
    @try {
        struct load_command *cmd =
            (struct load_command *)((uintptr_t)header + sizeof(struct mach_header_64));
        // Hard bounds for every walk below: never read past the load
        // commands area (a corrupt/garbage ncmds once SIGBUS-killed us).
        const uintptr_t cmdsEnd =
            (uintptr_t)header + sizeof(struct mach_header_64) + header->sizeofcmds;

        struct symtab_command *symtab = NULL;
        struct dysymtab_command *dysymtab = NULL;

        // First pass: locate tables.
        for (uint32_t i = 0; i < header->ncmds; i++) {
            if ((uintptr_t)cmd + sizeof(struct load_command) > cmdsEnd) return;
            if (cmd->cmdsize < sizeof(struct load_command)) return;
            if ((uintptr_t)cmd + cmd->cmdsize > cmdsEnd) return;
            if (cmd->cmd == LC_SYMTAB) {
                symtab = (struct symtab_command *)cmd;
            } else if (cmd->cmd == LC_DYSYMTAB) {
                dysymtab = (struct dysymtab_command *)cmd;
            }
            cmd = (struct load_command *)((uintptr_t)cmd + cmd->cmdsize);
        }
        if (!symtab || !dysymtab || !symtab->nsyms) return;
        if (symtab->nsyms > 500000) return;

        // File offsets (symoff/stroff/indirectsymoff) must be translated
        // through __LINKEDIT: live = seg.vmaddr + slide + (off - seg.fileoff).
        // (Assuming fileoff==memory offset is what made naive parsers
        // read garbage on some images.)
        uintptr_t linkeditLive = 0;
        uint64_t linkeditFile = 0;
        {
            struct load_command *c =
                (struct load_command *)((uintptr_t)header + sizeof(struct mach_header_64));
            for (uint32_t i = 0; i < header->ncmds; i++) {
                if ((uintptr_t)c + sizeof(struct load_command) > cmdsEnd) break;
                if (c->cmdsize < sizeof(struct load_command)) break;
                if ((uintptr_t)c + c->cmdsize > cmdsEnd) break;
                if (c->cmd == LC_SEGMENT_64) {
                    struct segment_command_64 *sg = (struct segment_command_64 *)c;
                    if (strcmp(sg->segname, "__LINKEDIT") == 0) {
                        linkeditLive = (uintptr_t)sg->vmaddr + (uintptr_t)slide;
                        linkeditFile = sg->fileoff;
                        break;
                    }
                }
                c = (struct load_command *)((uintptr_t)c + c->cmdsize);
            }
        }
        if (!linkeditLive) return;
        if (symtab->symoff < linkeditFile || symtab->stroff < linkeditFile) return;
        if (dysymtab->indirectsymoff < linkeditFile) return;
        if (dysymtab->nindirectsyms > 1000000) return;

        const struct nlist_64 *symbols =
            (struct nlist_64 *)(linkeditLive + (symtab->symoff - linkeditFile));
        const char *strings =
            (const char *)(linkeditLive + (symtab->stroff - linkeditFile));
        const uint32_t *indirect =
            (uint32_t *)(linkeditLive + (dysymtab->indirectsymoff - linkeditFile));

        // Second pass: scan __DATA[(_CONST)] symbol-pointer sections.
        cmd = (struct load_command *)((uintptr_t)header + sizeof(struct mach_header_64));
        for (uint32_t i = 0; i < header->ncmds; i++) {
            if ((uintptr_t)cmd + sizeof(struct load_command) > cmdsEnd) return;
            if (cmd->cmdsize < sizeof(struct load_command)) return;
            if ((uintptr_t)cmd + cmd->cmdsize > cmdsEnd) return;
            if (cmd->cmd == LC_SEGMENT_64) {
                struct segment_command_64 *seg = (struct segment_command_64 *)cmd;
                if (strcmp(seg->segname, "__DATA") == 0 ||
                    strcmp(seg->segname, "__DATA_CONST") == 0) {
                    struct section_64 *sec =
                        (struct section_64 *)((uintptr_t)seg + sizeof(struct segment_command_64));
                    for (uint32_t s = 0; s < seg->nsects; s++, sec++) {
                        const uint8_t type = sec->flags & SECTION_TYPE;
                        if (type != S_LAZY_SYMBOL_POINTERS &&
                            type != S_NON_LAZY_SYMBOL_POINTERS) {
                            continue;
                        }
                        const uint32_t count = (uint32_t)(sec->size / sizeof(void *));
                        // sec->addr is the link-time vmaddr; the live
                        // address is vmaddr + slide.
                        void **pointers =
                            (void **)((uintptr_t)sec->addr + (uintptr_t)slide);
                        for (uint32_t e = 0; e < count; e++) {
                            const uint32_t tableIndex = sec->reserved1 + e;
                            if (tableIndex >= dysymtab->nindirectsyms) continue;
                            const uint32_t symIndex = indirect[tableIndex];
                            if (symIndex == INDIRECT_SYMBOL_ABS ||
                                symIndex == INDIRECT_SYMBOL_LOCAL ||
                                symIndex >= symtab->nsyms) {
                                continue;
                            }
                            const char *name = strings + symbols[symIndex].n_un.n_strx;
                            if (strcmp(name, targetName) == 0) {
                                void **slot = &pointers[e];
                                // __DATA_CONST is read-only: unlock the page.
                                const uintptr_t page =
                                    (uintptr_t)slot & ~(uintptr_t)(4095);
                                // Try 4K then 16K page sizes.
                                if (mprotect((void *)page, 4096,
                                             PROT_READ | PROT_WRITE) != 0) {
                                    const uintptr_t page16 =
                                        (uintptr_t)slot & ~(uintptr_t)(16383);
                                    if (mprotect((void *)page16, 16384,
                                                 PROT_READ | PROT_WRITE) != 0) {
                                        continue;
                                    }
                                }
                                *slot = replacement;
                            }
                        }
                    }
                }
            }
            cmd = (struct load_command *)((uintptr_t)cmd + cmd->cmdsize);
        }
    } @catch (NSException *e) {}
}

static void PARebindAll(const char *name, void *replacement) {
    // Only rebind the MAIN executable (dyld index 0). That is where the
    // game's integrity code lives, and its headers are always readable.
    // Walking every shared-cache image is what killed us: some images'
    // load-command area isn't mapped readable and hardware faults
    // (SIGBUS/SIGSEGV) can't be caught with @try/@catch.
    @try {
        const struct mach_header *hdr = _dyld_get_image_header(0);
        if (!hdr || hdr->magic != MH_MAGIC_64) return;
        const struct mach_header_64 *hdr64 = (const struct mach_header_64 *)hdr;
        // Sanity bounds: refuse absurd tables instead of walking off-image.
        if (hdr64->ncmds == 0 || hdr64->ncmds > 256) return;
        if (hdr64->sizeofcmds > 256 * 1024) return;
        const intptr_t slide = _dyld_get_image_vmaddr_slide(0);
        PARebindPointers((struct mach_header_64 *)hdr, slide,
                         name, replacement);
    } @catch (NSException *e) {}
}

// ---------------------------------------------------------------------------
// NSBundle allFrameworks filter.
// ---------------------------------------------------------------------------

static NSArray *PAFilteredFrameworks(NSArray *original) {
    NSMutableArray *kept = [NSMutableArray arrayWithCapacity:original.count];
    for (id bundle in original) {
        @try {
            NSString *path = nil;
            if ([bundle respondsToSelector:@selector(bundlePath)]) {
                path = [bundle bundlePath];
            }
            if (path &&
                ([path containsString:@"BloomKit"] ||
                 [path containsString:@"PoolAdmin"])) {
                continue;
            }
        } @catch (NSException *e) {}
        [kept addObject:bundle];
    }
    return kept;
}

static id PA_allFrameworks(id self, SEL _cmd) {
    Class cls = object_getClass(self);
    // Call through to the original (swapped) implementation.
    SEL alias = NSSelectorFromString(@"pa_original_allFrameworks");
    id (*orig)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    NSArray *all = nil;
    @try {
        all = orig(self, alias);
    } @catch (NSException *e) {
        return @[];
    }
    if (![all isKindOfClass:NSArray.class]) return all;
    return PAFilteredFrameworks(all);
}

@implementation PAImageHider

+ (BOOL)isHiddenImagePath:(const char *)path {
    return path ? PAIsHiddenPath(path) : NO;
}

+ (void)install {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSLog(@"[PoolAdmin] stage=hider begin");
        @try {
            // Capture the real implementations via direct dyld calls BEFORE
            // any rebinding (dlsym would return rebound pointers later).
            sRealCount = &_dyld_image_count;
            sRealName = &_dyld_get_image_name;

            PARebindAll("_dyld_image_count", (void *)&PA_image_count);
            PARebindAll("_dyld_get_image_name", (void *)&PA_image_name);

            // Filter +[NSBundle allFrameworks].
            Class meta = object_getClass((id)[NSBundle class]);
            SEL sel = @selector(allFrameworks);
            Method m = class_getClassMethod([NSBundle class], sel);
            if (m) {
                // Stash original under an alias, then swap.
                SEL alias = NSSelectorFromString(@"pa_original_allFrameworks");
                class_addMethod(meta, alias,
                                method_getImplementation(m),
                                method_getTypeEncoding(m));
                method_setImplementation(
                    m, (IMP)PA_allFrameworks);
            }
            NSLog(@"[PoolAdmin] stage=hider result=ok");
        } @catch (NSException *e) {
            NSLog(@"[PoolAdmin] stage=hider result=exception %@", e);
        }
    });
}

@end
