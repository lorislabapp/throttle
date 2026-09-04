import ResearchVaultServiceRuntime

@main
struct ResearchVaultAgentMain {
    static func main() async {
        await ResearchVaultServiceRuntime.run()
    }
}
