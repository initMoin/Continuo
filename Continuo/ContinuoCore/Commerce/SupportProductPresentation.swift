extension SupportProduct {
    var message: String {
        switch self {
        case .lemonCookie:
            "A small bite of thanks."
        case .caramelLatte:
            "For the builds that run past bedtime."
        case .phillyCheesesteak:
            "A hearty thank-you for keeping Continuo going."
        }
    }

    var assetName: String {
        switch self {
        case .lemonCookie:
            "supportCookie"
        case .caramelLatte:
            "supportCoffee"
        case .phillyCheesesteak:
            "supportCheesesteak"
        }
    }
}
