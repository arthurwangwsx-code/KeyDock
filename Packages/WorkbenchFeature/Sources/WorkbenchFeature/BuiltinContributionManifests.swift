import CommandCore

/// 纯声明供有效快捷键计划使用，不依赖App、OS权限或可执行闭包。
enum BuiltinContributionManifests {
    static func all() throws -> [ContributionManifest] {
        try [CalculatorContribution.manifest(),SavedCommandContribution.manifest(),FileSearchContribution.manifest()]
    }
    static func isCommandEnabled(_ id:String,disabled:Set<String>,manifests:[ContributionManifest]) -> Bool {
        guard let owner = manifests.first(where:{$0.ownsCommandID(id)}) else { return true }
        return !disabled.contains(owner.reference.toolID)
    }
}
