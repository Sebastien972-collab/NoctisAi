// Created by Sébastien DAGUIN

import XCTest
@testable import NoctisPresentation

final class NoctisPresentationTests: XCTestCase {

    func testSchemaVersionIsPositive() {
        XCTAssertGreaterThan(InterfaceDescription.currentSchemaVersion, 0)
    }

    func testCompoundAndLeafPartitionAllNodeTypes() {
        let withChildren: Set<InterfaceNodeType> = [.row, .column, .container, .list, .table, .menu]
        let leaves: Set<InterfaceNodeType> = [.text, .divider, .progress, .spinner, .input, .status]

        XCTAssertEqual(Set(InterfaceNodeType.allCases), withChildren.union(leaves))

        for type in InterfaceNodeType.allCases {
            XCTAssertEqual(withChildren.contains(type), type.allowsChildren, "\(type)")
            XCTAssertEqual(leaves.contains(type), !type.allowsChildren, "\(type)")
        }

        XCTAssertEqual(InterfaceNodeType.row.defaultLayout, .horizontal)
        XCTAssertEqual(InterfaceNodeType.column.defaultLayout, .vertical)
        XCTAssertNil(InterfaceNodeType.text.defaultLayout)
    }

    func testDescriptionRoundTrip() throws {
        let node = InterfaceNode(
            id: "root",
            type: .column,
            children: [
                .text("title", "Bonjour"),
                InterfaceNode(id: "bar", type: .progress, properties: ["value": .number(0.5)])
            ]
        )
        let description = InterfaceDescription(id: "greeting", title: "Accueil", root: node)

        let data = try JSONEncoder().encode(description)
        let decoded = try JSONDecoder().decode(InterfaceDescription.self, from: data)

        XCTAssertEqual(decoded, description)
        XCTAssertEqual(decoded.schemaVersion, InterfaceDescription.currentSchemaVersion)
    }

    func testValueRoundTrip() throws {
        let values: [InterfaceValue] = [
            .string("a"),
            .number(1.5),
            .bool(true),
            .null,
            .array([.string("x"), .number(2)]),
            .object(["k": .string("v")])
        ]

        let data = try JSONEncoder().encode(values)
        let decoded = try JSONDecoder().decode([InterfaceValue].self, from: data)

        XCTAssertEqual(decoded, values)
    }

    func testValueDecodesPlainJSON() throws {
        let data = Data(#"{"a":1,"b":[true,null],"c":"x"}"#.utf8)
        let value = try JSONDecoder().decode(InterfaceValue.self, from: data)

        XCTAssertEqual(
            value,
            .object([
                "a": .number(1),
                "b": .array([.bool(true), .null]),
                "c": .string("x")
            ])
        )
    }
}
