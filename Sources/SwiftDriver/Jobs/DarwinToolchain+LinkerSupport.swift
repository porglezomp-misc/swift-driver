import TSCBasic
import TSCUtility

extension DarwinToolchain {
  private func findARCLiteLibPath() throws -> AbsolutePath? {
    let path = try getToolPath(.swiftCompiler)
      .parentDirectory // 'swift'
      .parentDirectory // 'bin'
      .appending(components: "lib", "arc")

    if localFileSystem.exists(path) { return path }

    // If we don't have a 'lib/arc/' directory, find the "arclite" library
    // relative to the Clang in the active Xcode.
    if let clangPath = try? getToolPath(.clang) {
      return clangPath
        .parentDirectory // 'clang'
        .parentDirectory // 'bin'
        .appending(components: "lib", "arc")
    }
    return nil
  }

  private func addProfileGenerationArgs(
    to commandLine: inout [Job.ArgTemplate],
    parsedOptions: inout ParsedOptions,
    targetTriple: Triple
  ) throws {
    guard parsedOptions.hasArgument(.profileGenerate) else { return }
    let clangPath = try clangLibraryPath(for: targetTriple,
                                         parsedOptions: &parsedOptions)

    let runtime = targetTriple.darwinPlatform!.libraryNameSuffix

    let clangRTPath = clangPath
      .appending(component: "libclang_rt.profile_\(runtime).a")

    commandLine.appendPath(clangRTPath)
  }

  private func addDeploymentTargetArgs(
    to commandLine: inout [Job.ArgTemplate],
    targetTriple: Triple
  ) {
    // FIXME: Properly handle deployment targets.
    
    let flag: String
    
    switch targetTriple.darwinPlatform! {
    case .iOS(.device):
      flag = "-iphoneos_version_min"
    case .iOS(.simulator):
      flag = "-ios_simulator_version_min"
    case .macOS:
      flag = "-macosx_version_min"
    case .tvOS(.device):
      flag = "-tvos_version_min"
    case .tvOS(.simulator):
      flag = "-tvos_simulator_version_min"
    case .watchOS(.device):
      flag = "-watchos_version_min"
    case .watchOS(.simulator):
      flag = "-watchos_simulator_version_min"
    }
    
    commandLine.appendFlag(flag)
    commandLine.appendFlag(targetTriple.version().description)
  }
  
  private func addArgsToLinkARCLite(
    to commandLine: inout [Job.ArgTemplate],
    parsedOptions: inout ParsedOptions,
    targetTriple: Triple
  ) throws {
    guard parsedOptions.hasFlag(
      positive: .linkObjcRuntime,
      negative: .noLinkObjcRuntime,
      default: !targetTriple.supports(.compatibleObjCRuntime)
    ) else {
      return
    }

    guard let arcLiteLibPath = try findARCLiteLibPath(),
      let platformName = targetTriple.platformName() else {
        return
    }
    let fullLibPath = arcLiteLibPath
      .appending(components: "libarclite_\(platformName).a")

    commandLine.appendFlag("-force_load")
    commandLine.appendPath(fullLibPath)

    // Arclite depends on CoreFoundation.
    commandLine.appendFlag(.framework)
    commandLine.appendFlag("CoreFoundation")
  }

  /// Adds the arguments necessary to link the files from the given set of
  /// options for a Darwin platform.
  public func addPlatformSpecificLinkerArgs(
    to commandLine: inout [Job.ArgTemplate],
    parsedOptions: inout ParsedOptions,
    linkerOutputType: LinkOutputType,
    inputs: [TypedVirtualPath],
    outputFile: VirtualPath,
    sdkPath: String?,
    targetTriple: Triple
  ) throws -> AbsolutePath {

    // FIXME: If we used Clang as a linker instead of going straight to ld,
    // we wouldn't have to replicate a bunch of Clang's logic here.

    // Always link the regular compiler_rt if it's present. Note that the
    // regular libclang_rt.a uses a fat binary for device and simulator; this is
    // not true for all compiler_rt build products.
    //
    // Note: Normally we'd just add this unconditionally, but it's valid to build
    // Swift and use it as a linker without building compiler_rt.
    let darwinPlatformSuffix =
        targetTriple.darwinPlatform!.with(.device)!.libraryNameSuffix
    let compilerRTPath =
      try clangLibraryPath(
        for: targetTriple, parsedOptions: &parsedOptions)
      .appending(component: "libclang_rt.\(darwinPlatformSuffix).a")
    if localFileSystem.exists(compilerRTPath) {
      commandLine.append(.path(.absolute(compilerRTPath)))
    }

    // Set up for linking.
    let linkerTool: Tool
    switch linkerOutputType {
    case .dynamicLibrary:
      // Same as an executable, but with the -dylib flag
      commandLine.appendFlag("-dylib")
      fallthrough
    case .executable:
      linkerTool = .dynamicLinker
      let fSystemArgs = parsedOptions.filter {
        $0.option == .F || $0.option == .Fsystem
      }
      for opt in fSystemArgs {
        commandLine.appendFlag(.F)
        commandLine.appendPath(try VirtualPath(path: opt.argument.asSingle))
      }

      // FIXME: Sanitizer args

      commandLine.appendFlag("-arch")
      commandLine.appendFlag(targetTriple.archName)

      try addArgsToLinkStdlib(
        to: &commandLine,
        parsedOptions: &parsedOptions,
        sdkPath: sdkPath,
        targetTriple: targetTriple
      )

      // These custom arguments should be right before the object file at the
      // end.
      try commandLine.append(
        contentsOf: parsedOptions.filter { $0.option.group == .linkerOption }
      )
      try commandLine.appendAllArguments(.Xlinker, from: &parsedOptions)

    case .staticLibrary:
      linkerTool = .staticLinker
      commandLine.appendFlag(.static)
      break
    }

    try addArgsToLinkARCLite(
      to: &commandLine,
      parsedOptions: &parsedOptions,
      targetTriple: targetTriple
    )
    addDeploymentTargetArgs(
      to: &commandLine,
      targetTriple: targetTriple
    )
    try addProfileGenerationArgs(
      to: &commandLine,
      parsedOptions: &parsedOptions,
      targetTriple: targetTriple
    )

    commandLine.appendFlags(
      "-lobjc",
      "-lSystem",
      "-no_objc_category_merging"
    )

    // Add the SDK path
    if let sdkPath = sdkPath {
      commandLine.appendFlag("-syslibroot")
      commandLine.appendPath(try VirtualPath(path: sdkPath))
    }

    if parsedOptions.contains(.embedBitcode) ||
      parsedOptions.contains(.embedBitcodeMarker) {
      commandLine.appendFlag("-bitcode_bundle")
    }

    if parsedOptions.contains(.enableAppExtension) {
      commandLine.appendFlag("-application_extension")
    }

    // Add inputs.
    commandLine.append(contentsOf: inputs.map { .path($0.file) })

    // Add the output
    commandLine.appendFlag("-o")
    commandLine.appendPath(outputFile)

    return try getToolPath(linkerTool)
  }
}
