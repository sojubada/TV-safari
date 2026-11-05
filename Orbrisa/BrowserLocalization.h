//
//  BrowserLocalization.h
//  Orbrisa
//

#import <Foundation/Foundation.h>

/// Texts in the code are English. German translations live in de.lproj/Localizable.strings;
/// every other system language falls back to English.
#define BrowserLocalized(englishText) NSLocalizedString(englishText, nil)
