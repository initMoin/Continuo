//
//  Item.swift
//  Continuo
//
//  Created by Moinuddin Ahmad on 8/14/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
