import Foundation
import Testing
@testable import ClipSlop

@Suite("JSONValue")
struct JSONValueTests {

    @Test("Integers encode without a decimal point")
    func integerEncoding() {
        #expect(JSONValue.int(4096).jsonString() == "4096")
    }

    @Test("Round-trips an object through parse and jsonString")
    func objectRoundTrip() {
        let source = #"{"a":"x","b":true,"c":[1,2,3]}"#
        let value = JSONValue.parse(source)
        #expect(value.objectValue?["a"]?.stringValue == "x")
        #expect(value.objectValue?["b"]?.boolValue == true)
        #expect(value.objectValue?["c"]?.arrayValue?.count == 3)
        // Re-parsing the serialized form yields an equal tree.
        #expect(JSONValue.parse(value.jsonString()) == value)
    }

    @Test("Malformed JSON parses to an empty object")
    func malformedFallsBack() {
        #expect(JSONValue.parse("not json") == .object([:]))
    }

    @Test("String accessor returns nil for non-strings")
    func typedAccessors() {
        #expect(JSONValue.bool(true).stringValue == nil)
        #expect(JSONValue.string("hi").boolValue == nil)
    }
}

@Suite("PromptLibraryTools")
struct PromptLibraryToolsTests {

    @Test("Every tool schema is a valid JSON object")
    func schemasAreValidObjects() {
        for tool in PromptLibraryTools.all {
            let schema = JSONValue.parse(tool.parametersSchemaJSON)
            #expect(schema.objectValue != nil, "\(tool.name) schema is not an object")
            #expect(schema.objectValue?["type"]?.stringValue == "object", "\(tool.name) schema type is not object")
        }
    }

    @Test("Read-only tools are not marked mutating")
    func readOnlyClassification() {
        #expect(PromptLibraryTools.isMutating("list_library") == false)
        #expect(PromptLibraryTools.isMutating("get_prompt") == false)
    }

    @Test("Mutating tools are marked mutating")
    func mutatingClassification() {
        for name in ["create_prompt", "update_prompt", "delete_node", "move_node", "set_shortcut", "clear_shortcut"] {
            #expect(PromptLibraryTools.isMutating(name), "\(name) should be mutating")
        }
    }

    @Test("Tool names are unique")
    func uniqueNames() {
        let names = PromptLibraryTools.all.map(\.name)
        #expect(Set(names).count == names.count)
    }
}
