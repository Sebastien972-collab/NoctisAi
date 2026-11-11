import Foundation

public struct InterfaceReconciler: Sendable {
    public let validator: InterfaceValidator

    public init(validator: InterfaceValidator = InterfaceValidator()) { self.validator = validator }

    /// Produces a validated copy. The caller only swaps state after this succeeds, making mutations atomic.
    public func applying(_ mutation: InterfaceMutation, to current: InterfaceDescription) throws -> InterfaceDescription? {
        guard mutation.schemaVersion == current.schemaVersion else { throw InterfaceValidationError.unsupportedSchemaVersion }
        guard mutation.interfaceID == current.id else { throw InterfaceValidationError.targetNotFound }
        guard mutation.baseRevision == current.revision, mutation.revision == current.revision + 1 else {
            throw InterfaceValidationError.invalidRevision
        }
        if case .dismiss = mutation.operation { return nil }
        var root = current.root
        let changed: Bool
        switch mutation.operation {
        case .update(let target, let properties):
            changed = mutate(&root, target: target) { $0.properties.merge(properties) { _, new in new } }
        case .append(let parent, let node):
            guard find(parent, in: root)?.type.allowsChildren == true else {
                throw InterfaceValidationError.incompatibleMutation
            }
            changed = mutate(&root, target: parent) { $0.children.append(node) }
        case .remove(let target):
            guard target != root.id else { throw InterfaceValidationError.incompatibleMutation }
            changed = remove(target, from: &root)
        case .replace(let target, let node):
            if root.id == target { root = node; changed = true } else { changed = replace(target, with: node, in: &root) }
        case .reorder(let parent, let childIDs):
            guard let parentNode = find(parent, in: root),
                  Set(parentNode.children.map(\.id)) == Set(childIDs),
                  parentNode.children.count == childIDs.count else {
                throw InterfaceValidationError.incompatibleMutation
            }
            changed = mutate(&root, target: parent) { candidate in
                let byID = Dictionary(uniqueKeysWithValues: candidate.children.map { ($0.id, $0) })
                candidate.children = childIDs.compactMap { byID[$0] }
            }
        case .dismiss: changed = false
        }
        guard changed else { throw InterfaceValidationError.targetNotFound }
        let next = InterfaceDescription(schemaVersion: current.schemaVersion, revision: mutation.revision,
                                        id: current.id, title: current.title, root: root)
        try validator.validate(next)
        return next
    }

    private func find(_ target: String, in node: InterfaceNode) -> InterfaceNode? {
        if node.id == target { return node }
        for child in node.children {
            if let match = find(target, in: child) { return match }
        }
        return nil
    }

    private func mutate(_ node: inout InterfaceNode, target: String, body: (inout InterfaceNode) -> Void) -> Bool {
        if node.id == target { body(&node); return true }
        for index in node.children.indices where mutate(&node.children[index], target: target, body: body) { return true }
        return false
    }

    private func remove(_ target: String, from node: inout InterfaceNode) -> Bool {
        if let index = node.children.firstIndex(where: { $0.id == target }) { node.children.remove(at: index); return true }
        for index in node.children.indices where remove(target, from: &node.children[index]) { return true }
        return false
    }

    private func replace(_ target: String, with replacement: InterfaceNode, in node: inout InterfaceNode) -> Bool {
        if let index = node.children.firstIndex(where: { $0.id == target }) { node.children[index] = replacement; return true }
        for index in node.children.indices where replace(target, with: replacement, in: &node.children[index]) { return true }
        return false
    }
}
