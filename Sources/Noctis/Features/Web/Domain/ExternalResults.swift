//
//  ExternalResults.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 04/11/2026.
//

import Foundation

struct ExternalResults: Encodable {
    let trust: String
    let instructions: String
    let results: [ExternalResult]
}
