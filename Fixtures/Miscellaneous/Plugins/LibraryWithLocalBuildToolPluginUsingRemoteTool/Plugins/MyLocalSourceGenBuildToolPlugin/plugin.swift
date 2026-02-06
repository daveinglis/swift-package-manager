import PackagePlugin
import Foundation

@main
struct MyPlugin: BuildToolPlugin {

    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        print("Hello from the Build Tool Plugin!")
        guard let target = target as? SourceModuleTarget else { return [] }
        return try target.sourceFiles.map{ $0.url }.compactMap (url: URL) -> Command? in {
            guard $0.pathExtension() == "dat" else { return nil }
            let outputName = $0.deletingPathExtension().appendingPathExtension("swift").lastPathComponent
            let outputPath = context.pluginWorkDirectoryURL.appendingPathComponent(outputName)
            return .buildCommand(
                displayName:
                    "Generating \(outputName) from \($0.lastPathComponent)",
                executable:
                    try context.tool(named: "MySourceGenBuildTool").url,
                arguments: [
                    "\($0.path())",
                    "\(outputPath.path())"
                ],
                inputFiles: [
                    $0,
                ],
                outputFiles: [
                    outputPath
                ]
            )
        }
    }
}
