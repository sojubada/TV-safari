#import "BrowserHangulComposer.h"

static const unichar kHangulSyllableBase = 0xAC00;

static const unichar kChoseong[19] = {
    0x3131, 0x3132, 0x3134, 0x3137, 0x3138, 0x3139, 0x3141, 0x3142, 0x3143,
    0x3145, 0x3146, 0x3147, 0x3148, 0x3149, 0x314A, 0x314B, 0x314C, 0x314D,
    0x314E
};

static const unichar kJungseong[21] = {
    0x314F, 0x3150, 0x3151, 0x3152, 0x3153, 0x3154, 0x3155, 0x3156, 0x3157,
    0x3158, 0x3159, 0x315A, 0x315B, 0x315C, 0x315D, 0x315E, 0x315F, 0x3160,
    0x3161, 0x3162, 0x3163
};

// Index 0 is "no final consonant", which keeps the arithmetic below honest.
static const unichar kJongseong[28] = {
    0x0000, 0x3131, 0x3132, 0x3133, 0x3134, 0x3135, 0x3136, 0x3137, 0x3139,
    0x313A, 0x313B, 0x313C, 0x313D, 0x313E, 0x313F, 0x3140, 0x3141, 0x3142,
    0x3144, 0x3145, 0x3146, 0x3147, 0x3148, 0x314A, 0x314B, 0x314C, 0x314D,
    0x314E
};

typedef struct {
    unichar first;
    unichar second;
    unichar combined;
} BrowserJamoPair;

static const BrowserJamoPair kVowelPairs[] = {
    {0x3157, 0x314F, 0x3158}, {0x3157, 0x3150, 0x3159}, {0x3157, 0x3163, 0x315A},
    {0x315C, 0x3153, 0x315D}, {0x315C, 0x3154, 0x315E}, {0x315C, 0x3163, 0x315F},
    {0x3161, 0x3163, 0x3162}
};

static const BrowserJamoPair kFinalPairs[] = {
    {0x3131, 0x3145, 0x3133}, {0x3134, 0x3148, 0x3135}, {0x3134, 0x314E, 0x3136},
    {0x3139, 0x3131, 0x313A}, {0x3139, 0x3141, 0x313B}, {0x3139, 0x3142, 0x313C},
    {0x3139, 0x3145, 0x313D}, {0x3139, 0x314C, 0x313E}, {0x3139, 0x314D, 0x313F},
    {0x3139, 0x314E, 0x3140}, {0x3142, 0x3145, 0x3144}
};

static NSInteger BrowserIndexInTable(const unichar *table, NSInteger count, unichar value) {
    if (value == 0) {
        return -1;
    }
    for (NSInteger i = 0; i < count; i++) {
        if (table[i] == value) {
            return i;
        }
    }
    return -1;
}

static unichar BrowserCombineJamo(const BrowserJamoPair *pairs, NSInteger count, unichar first, unichar second) {
    for (NSInteger i = 0; i < count; i++) {
        if (pairs[i].first == first && pairs[i].second == second) {
            return pairs[i].combined;
        }
    }
    return 0;
}

static BOOL BrowserSplitJamo(const BrowserJamoPair *pairs, NSInteger count, unichar combined,
                             unichar *outFirst, unichar *outSecond) {
    for (NSInteger i = 0; i < count; i++) {
        if (pairs[i].combined == combined) {
            if (outFirst != NULL) { *outFirst = pairs[i].first; }
            if (outSecond != NULL) { *outSecond = pairs[i].second; }
            return YES;
        }
    }
    return NO;
}

static BOOL BrowserIsVowelJamo(unichar jamo) {
    return BrowserIndexInTable(kJungseong, 21, jamo) >= 0;
}

@interface BrowserHangulComposer ()
// -1 means "not set". The final consonant uses 0 for "none" so it can index
// kJongseong directly.
@property (nonatomic) NSInteger choIndex;
@property (nonatomic) NSInteger jungIndex;
@property (nonatomic) NSInteger jongIndex;
@end

@implementation BrowserHangulComposer

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        [self reset];
    }
    return self;
}

- (void)reset {
    _choIndex = -1;
    _jungIndex = -1;
    _jongIndex = 0;
}

+ (unichar)jamoForLatinCharacter:(unichar)character {
    switch (character) {
        case 'q': return 0x3142; case 'Q': return 0x3143;
        case 'w': return 0x3148; case 'W': return 0x3149;
        case 'e': return 0x3137; case 'E': return 0x3138;
        case 'r': return 0x3131; case 'R': return 0x3132;
        case 't': return 0x3145; case 'T': return 0x3146;
        case 'y': return 0x315B; case 'Y': return 0x315B;
        case 'u': return 0x3155; case 'U': return 0x3155;
        case 'i': return 0x3151; case 'I': return 0x3151;
        case 'o': return 0x3150; case 'O': return 0x3152;
        case 'p': return 0x3154; case 'P': return 0x3156;
        case 'a': return 0x3141; case 'A': return 0x3141;
        case 's': return 0x3134; case 'S': return 0x3134;
        case 'd': return 0x3147; case 'D': return 0x3147;
        case 'f': return 0x3139; case 'F': return 0x3139;
        case 'g': return 0x314E; case 'G': return 0x314E;
        case 'h': return 0x3157; case 'H': return 0x3157;
        case 'j': return 0x3153; case 'J': return 0x3153;
        case 'k': return 0x314F; case 'K': return 0x314F;
        case 'l': return 0x3163; case 'L': return 0x3163;
        case 'z': return 0x314B; case 'Z': return 0x314B;
        case 'x': return 0x314C; case 'X': return 0x314C;
        case 'c': return 0x314A; case 'C': return 0x314A;
        case 'v': return 0x314D; case 'V': return 0x314D;
        case 'b': return 0x3160; case 'B': return 0x3160;
        case 'n': return 0x315C; case 'N': return 0x315C;
        case 'm': return 0x3161; case 'M': return 0x3161;
        default: return 0;
    }
}

- (NSString *)composingText {
    if (self.choIndex >= 0 && self.jungIndex >= 0) {
        unichar syllable = (unichar)(kHangulSyllableBase +
                                     ((self.choIndex * 21) + self.jungIndex) * 28 +
                                     self.jongIndex);
        return [NSString stringWithCharacters:&syllable length:1];
    }
    if (self.choIndex >= 0) {
        unichar jamo = kChoseong[self.choIndex];
        return [NSString stringWithCharacters:&jamo length:1];
    }
    if (self.jungIndex >= 0) {
        unichar jamo = kJungseong[self.jungIndex];
        return [NSString stringWithCharacters:&jamo length:1];
    }
    return @"";
}

- (NSString *)flush {
    NSString *text = [self composingText];
    [self reset];
    return text;
}

- (NSString *)inputJamo:(unichar)jamo {
    if (jamo == 0) {
        return @"";
    }
    return BrowserIsVowelJamo(jamo) ? [self inputVowel:jamo] : [self inputConsonant:jamo];
}

- (NSString *)inputConsonant:(unichar)jamo {
    NSInteger asCho = BrowserIndexInTable(kChoseong, 19, jamo);
    NSInteger asJong = BrowserIndexInTable(kJongseong, 28, jamo);

    // Nothing in progress: the consonant starts a syllable.
    if (self.choIndex < 0 && self.jungIndex < 0) {
        if (asCho >= 0) {
            self.choIndex = asCho;
            return @"";
        }
        return [NSString stringWithCharacters:&jamo length:1];
    }

    // A lone leading consonant followed by another: the first one stands on
    // its own, as it does in ㄱㄴㄷ.
    if (self.jungIndex < 0) {
        NSString *settled = [self flush];
        if (asCho >= 0) {
            self.choIndex = asCho;
            return settled;
        }
        return [settled stringByAppendingString:[NSString stringWithCharacters:&jamo length:1]];
    }

    // A vowel is in place, so the consonant tries to become the final.
    if (self.jongIndex == 0) {
        if (asJong > 0 && self.choIndex >= 0) {
            self.jongIndex = asJong;
            return @"";
        }
    } else {
        unichar current = kJongseong[self.jongIndex];
        unichar combined = BrowserCombineJamo(kFinalPairs,
                                              sizeof(kFinalPairs) / sizeof(kFinalPairs[0]),
                                              current, jamo);
        if (combined != 0) {
            NSInteger combinedIndex = BrowserIndexInTable(kJongseong, 28, combined);
            if (combinedIndex > 0) {
                self.jongIndex = combinedIndex;
                return @"";
            }
        }
    }

    NSString *settled = [self flush];
    if (asCho >= 0) {
        self.choIndex = asCho;
        return settled;
    }
    return [settled stringByAppendingString:[NSString stringWithCharacters:&jamo length:1]];
}

- (NSString *)inputVowel:(unichar)jamo {
    NSInteger asJung = BrowserIndexInTable(kJungseong, 21, jamo);
    if (asJung < 0) {
        return @"";
    }

    // A vowel after a final consonant takes that consonant with it: 간 + ㅏ
    // is 가나, because the ㄴ belongs to the new syllable.
    if (self.jongIndex > 0) {
        unichar jong = kJongseong[self.jongIndex];
        unichar carriedFirst = 0;
        unichar carriedSecond = 0;
        unichar movedConsonant = jong;
        if (BrowserSplitJamo(kFinalPairs,
                             sizeof(kFinalPairs) / sizeof(kFinalPairs[0]),
                             jong, &carriedFirst, &carriedSecond)) {
            NSInteger remaining = BrowserIndexInTable(kJongseong, 28, carriedFirst);
            self.jongIndex = (remaining > 0) ? remaining : 0;
            movedConsonant = carriedSecond;
        } else {
            self.jongIndex = 0;
        }

        NSString *settled = [self flush];
        NSInteger movedCho = BrowserIndexInTable(kChoseong, 19, movedConsonant);
        if (movedCho >= 0) {
            self.choIndex = movedCho;
            self.jungIndex = asJung;
            return settled;
        }
        self.jungIndex = asJung;
        return settled;
    }

    if (self.jungIndex >= 0) {
        unichar combined = BrowserCombineJamo(kVowelPairs,
                                              sizeof(kVowelPairs) / sizeof(kVowelPairs[0]),
                                              kJungseong[self.jungIndex], jamo);
        if (combined != 0) {
            NSInteger combinedIndex = BrowserIndexInTable(kJungseong, 21, combined);
            if (combinedIndex >= 0) {
                self.jungIndex = combinedIndex;
                return @"";
            }
        }
        NSString *settled = [self flush];
        self.jungIndex = asJung;
        return settled;
    }

    self.jungIndex = asJung;
    return @"";
}

- (BOOL)deleteBackward {
    if (self.jongIndex > 0) {
        unichar jong = kJongseong[self.jongIndex];
        unichar first = 0;
        if (BrowserSplitJamo(kFinalPairs,
                             sizeof(kFinalPairs) / sizeof(kFinalPairs[0]),
                             jong, &first, NULL)) {
            NSInteger remaining = BrowserIndexInTable(kJongseong, 28, first);
            self.jongIndex = (remaining > 0) ? remaining : 0;
        } else {
            self.jongIndex = 0;
        }
        return YES;
    }

    if (self.jungIndex >= 0) {
        unichar jung = kJungseong[self.jungIndex];
        unichar first = 0;
        if (BrowserSplitJamo(kVowelPairs,
                             sizeof(kVowelPairs) / sizeof(kVowelPairs[0]),
                             jung, &first, NULL)) {
            NSInteger remaining = BrowserIndexInTable(kJungseong, 21, first);
            self.jungIndex = (remaining >= 0) ? remaining : -1;
        } else {
            self.jungIndex = -1;
        }
        return YES;
    }

    if (self.choIndex >= 0) {
        self.choIndex = -1;
        return YES;
    }

    return NO;
}

@end
