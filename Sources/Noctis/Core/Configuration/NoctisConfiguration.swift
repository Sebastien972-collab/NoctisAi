//
//  NoctisConfiguration.swift
//  Noctis
//
//  Created by Sébastien DAGUIN on 03/11/2026.
//


public enum NoctisConfiguration {
#if os(macOS)
    public static let modelID =
    "mlx-community/Ministral-3-14B-Instruct-2512-4bit"
#else
    public static let modelID =
    "mlx-community/Ministral-3-3B-Instruct-2512-4bit"
#endif
    public static let assistantName = "Noctis"
    
    public static let exitCommand = "exit"
}
