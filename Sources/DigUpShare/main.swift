// An app extension is entered at `NSExtensionMain`, not at `main`: the linker
// flag in Package.swift redirects the Mach-O entry point, and NSExtensionMain
// instantiates `NSExtensionPrincipalClass` from this bundle's Info.plist.
