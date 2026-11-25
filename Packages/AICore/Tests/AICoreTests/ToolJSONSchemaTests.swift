import Foundation
import Testing
import AICore
import AgentCore
import ExecutionCore

struct ToolJSONSchemaTests {
    private func schema(additional:JSONValue? = nil) -> [String:JSONValue] {
        var schema: [String:JSONValue] = ["type":.string("object"),"title":.string("Synthetic tool"),"properties":.object([
            "text":.object(["type":.string("string"),"default":.string("kept as data"),"title":.string("Text")])
        ])]
        schema["additionalProperties"] = additional
        return schema
    }
    @Test func annotationsAreDataAndDefaultsNeverSatisfyRequiredOrInsertArguments() throws {
        var schema = schema()
        schema["default"] = .object(["unsupported_keyword_inside_data":.array([.number(1),.null])])
        schema["examples"] = .array([.string("An example need not match the schema")])
        schema["deprecated"] = .bool(false); schema["readOnly"] = .bool(true); schema["writeOnly"] = .bool(false)
        try ToolJSONSchema.checkSchema(schema)
        let input = JSONValue.object([:]); try ToolJSONSchema.validate(input,schema:schema)
        #expect(input == .object([:]))
        schema["required"] = .array([.string("text")])
        #expect(throws:AIProviderError.invalidToolArguments) { try ToolJSONSchema.validate(input,schema:schema) }
    }
    @Test(arguments:[nil,JSONValue.bool(true),.bool(false)])
    func declaredFieldsAndAdditionalPropertiesRetainTheirActualMeaning(_ additional:JSONValue?) throws {
        let value = schema(additional:additional)
        try ToolJSONSchema.checkSchema(value)
        #expect(throws:AIProviderError.invalidToolArguments) { try ToolJSONSchema.validate(.object(["text":.number(1)]),schema:value) }
        let extra = JSONValue.object(["extra":.object(["nested":.array([.number(1),.bool(true)])])])
        if additional == .bool(false) {
            #expect(throws:AIProviderError.invalidToolArguments) { try ToolJSONSchema.validate(extra,schema:value) }
        } else { try ToolJSONSchema.validate(extra,schema:value) }
    }
    @Test func omittedPropertiesAndRequiredUndeclaredNamesUseStandardOpenObjectSemantics() throws {
        var value: [String:JSONValue] = ["type":.string("object"),"required":.array([.string("present")])]
        try ToolJSONSchema.checkSchema(value)
        try ToolJSONSchema.validate(.object(["present":.null]),schema:value)
        #expect(throws:AIProviderError.invalidToolArguments) { try ToolJSONSchema.validate(.object([:]),schema:value) }
        value["additionalProperties"] = .bool(false)
        try ToolJSONSchema.checkSchema(value)
        #expect(throws:AIProviderError.invalidToolArguments) { try ToolJSONSchema.validate(.object(["present":.null]),schema:value) }
    }
    @Test func additionalPropertySchemaIsValidatedAndUnknownConstraintsCannotBeBypassed() throws {
        let value = schema(additional:.object(["type":.string("integer"),"minimum":.number(0)]))
        try ToolJSONSchema.checkSchema(value)
        try ToolJSONSchema.validate(.object(["extra":.number(2)]),schema:value)
        #expect(throws:AIProviderError.invalidToolArguments) { try ToolJSONSchema.validate(.object(["extra":.number(-1)]),schema:value) }
        for keyword in ["pattern","format","oneOf","anyOf","$ref"] {
            var unsupported = schema(); unsupported[keyword] = .string("synthetic")
            #expect(throws:AIProviderError.invalidToolSchema) { try ToolJSONSchema.checkSchema(unsupported) }
            #expect(throws:AIProviderError.invalidToolSchema) { try ToolJSONSchema.validate(.object([:]),schema:unsupported) }
        }
    }
    @Test func invalidAnnotationsAndOversizedOrDeepMetadataAreRejected() throws {
        for (key,value) in [("title",JSONValue.number(1)),("description",.bool(true)),("examples",.object([:])),("deprecated",.string("true")),("readOnly",.number(1))] {
            var invalid = schema(); invalid[key] = value
            #expect(throws:AIProviderError.invalidToolSchema) { try ToolJSONSchema.checkSchema(invalid) }
        }
        var huge = schema(); huge["default"] = .string(String(repeating:"x",count:65_537))
        #expect(throws:AIProviderError.invalidToolSchema) { try ToolJSONSchema.checkSchema(huge) }
        var nested = JSONValue.null
        for _ in 0..<34 { nested = .array([nested]) }
        var deep = schema(); deep["default"] = nested
        #expect(throws:AIProviderError.invalidToolSchema) { try ToolJSONSchema.checkSchema(deep) }
        #expect(throws:AIProviderError.invalidToolArguments) { try ToolJSONSchema.validate(.object(["extra":nested]),schema:schema()) }
        #expect(throws:AIProviderError.invalidToolArguments) { try ToolJSONSchema.validate(.object(["extra":.number(.infinity)]),schema:schema()) }
    }
    @Test func stringBoundsAndEnumsCompareCodePointsInsteadOfGraphemeEquivalence() throws {
        let value: [String:JSONValue] = ["type":.string("object"),"properties":.object(["text":.object(["type":.string("string"),"maxLength":.number(1)])])]
        try ToolJSONSchema.validate(.object(["text":.string("é")]),schema:value)
        try ToolJSONSchema.validate(.object(["text":.string("🚀")]),schema:value)
        #expect(throws:AIProviderError.invalidToolArguments) { try ToolJSONSchema.validate(.object(["text":.string("e\u{301}")]),schema:value) }
        let enumerated: [String:JSONValue] = ["type":.string("object"),"enum":.array([.object(["text":.string("é")])])]
        #expect(throws:AIProviderError.invalidToolArguments) { try ToolJSONSchema.validate(.object(["text":.string("e\u{301}")]),schema:enumerated) }
    }
    @Test func annotationsCannotApproveAnEffectfulTool() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("KeyDock-Schema-Approval-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let journal = try InvocationStore(directory:folder)
        var schema = schema(); schema["readOnly"] = .bool(true)
        let tool = ScopedAITool(definition:.init(name:"synthetic_effect",description:"Synthetic",parameters:schema),effects:[.writeFile],resource:.exact(namespace:"synthetic",identifier:"owned"),approvalSummary:"Synthetic effect") { _,_ in Issue.record("Denied annotation tool was dispatched"); return "" }
        let broker = try ScopedToolBroker(runID:UUID(),tools:[tool],journal:journal) { _ in false }
        await #expect(throws:AgentToolError.denied) { try await broker.invoke(.init(id:"denied",name:"synthetic_effect",arguments:"{}"),allowed:["synthetic_effect"]) }
        #expect(await journal.list().isEmpty)
        await broker.close(cancel:true)
    }
}
