// The Swift Programming Language
// https://docs.swift.org/swift-book
import Foundation


@main
struct Noctis {

    static func main() async {
        let application = NoctisApplication(
            modelService: MLXModelService()
        )

        await application.run()
    }
}
