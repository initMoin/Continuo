import CoreText
import Foundation

enum ContinuoFontRegistrar {
    static func registerBundledFonts() {
        let resourceNames = [
            ContinuoDesign.Typography.titleFontFileName,
            "Aleo-VariableFont_wght.ttf",
            "Aleo-Italic-VariableFont_wght.ttf"
        ]
        for resourceName in resourceNames {
            guard let resourceURL = Bundle.main.url(forResource: resourceName, withExtension: nil) else {
                continue
            }
            CTFontManagerRegisterFontsForURL(resourceURL as CFURL, .process, nil)
        }
    }
}
