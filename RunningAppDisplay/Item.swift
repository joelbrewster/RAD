//
//  Item.swift
//  RunningAppDisplay
//
//  Created by Joel Brewster on 25/1/2025.
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
