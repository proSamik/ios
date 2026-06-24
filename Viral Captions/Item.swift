//
//  Item.swift
//  Viral Captions
//
//  Created by Samik Choudhury on 25/06/26.
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
