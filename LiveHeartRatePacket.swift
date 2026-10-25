//
//  LiveHeartRatePacket.swift
//  Real Hydrasense
//
//  Created by Nikhil K on 9/26/26.
//

import Foundation

struct LiveHeartRatePacket: Codable {
    let heartRate: Double
    let timestamp: Date
}
