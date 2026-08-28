import ResearchVaultServiceRuntime

@main
struct ResearchVaultXPCServiceMain {
    static func main() async {
        await ResearchVaultServiceRuntime.run()
    }
}
