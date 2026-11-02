// The Swift Programming Language
// https://docs.swift.org/swift-book
import Foundation
import MLXLMCommon
import MLXVLM
import HuggingFace
import Tokenizers
import MLXHuggingFace

@main
struct Noctis {
    
    private static let modelId = "mlx-community/Ministral-3-14B-Instruct-2512-4bit"
    static func main() async {
        print("🌙 Noctis")
        print("Hello, Sebby!")
        
        do {
            print("Chargement de Ministral 3...")
            print("Le premier lancement peut nécessiter un téléchargement.")
            print()
            let model = try await loadModel(
                from: #hubDownloader,
                using: #huggingFaceTokenizerLoader(),
                id: modelId)
            
            let session = ChatSession(model, instructions: NoctisIdentity.systemPrompt)
            
            print("Tout est prêt !")
            print("Tape exit pour quitter")
            
            while true {
                print("Vous > ", terminator: "")
                fflush(stdout)
                
                guard let input = readLine() else {
                    break
                }
                
                let prompt = input.trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
                
                if prompt.lowercased() == "exit" {
                    break
                }
                
                guard !prompt.isEmpty else {
                    continue
                }
                
                do {
                    print()
                    print("Noctis 🌙 > ", terminator: "")
                    fflush(stdout)
                    for try await chunk in session.streamResponse(to: prompt) {
                        print(chunk, terminator: "")
                        fflush(stdout)
                    }
                    print("\n")
                    
                } catch {
                    print()
                    print("Une erreur lors de la génération: \(error.localizedDescription)")
                }
            }
        } catch  {
            print("Impossible de charger Noctis.")
            print("Erreur : \(error)")
        }
        
        print("🌑 Noctis teminé")
    }
}
