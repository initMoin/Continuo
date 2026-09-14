extension SupportProduct {
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
