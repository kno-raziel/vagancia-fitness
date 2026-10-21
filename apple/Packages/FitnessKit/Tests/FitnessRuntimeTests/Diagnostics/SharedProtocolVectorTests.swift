import FitnessCore
import Foundation
import Testing

struct SharedProtocolVectorTests {
    @Test func publicFitShowVectorsDefineRecognitionWithoutMotorAuthority() throws {
        struct Corpus: Decodable {
            struct Row: Decodable {
                let id: String
                let frameHex: String
                let family: UInt8?
                let parameter: UInt8?
                let recognized: Bool?
                let error: String?
            }
            let schemaVersion: Int
            let cases: [Row]
        }
        let url = try #require(
            Bundle.module.url(forResource: "PublicFitShowVectors", withExtension: "json"))
        let corpus = try JSONDecoder().decode(Corpus.self, from: Data(contentsOf: url))
        #expect(corpus.schemaVersion == 1)
        #expect(corpus.cases.count >= 5)
        for row in corpus.cases {
            let bytes = try #require(Data(hex: row.frameHex))
            if row.error != nil {
                #expect(throws: FitShowError.self) { try FitShowProtocol.decode(bytes) }
            } else {
                let message = try FitShowProtocol.decode(bytes)
                #expect(message.family == row.family)
                #expect(message.parameter == row.parameter)
                #expect(message.recognized == row.recognized)
            }
        }
    }
}
