//
//  NoctisConfiguration.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//


public enum NoctisConfiguration {
    #if os(macOS)
    public static let modelID = MLXModelProfile.gptOSSModelID
    #else
    public static let modelID = BonsaiModelConfiguration.modelID
    #endif
    public static let assistantName = "Noctis"
    
    public static let exitCommand = "exit"
}
