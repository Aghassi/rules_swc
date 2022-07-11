"Internal implementation details"

load("@bazel_skylib//lib:paths.bzl", "paths")
load("@aspect_bazel_lib//lib:copy_to_bin.bzl", "copy_file_to_bin_action")

_attrs = {
    "srcs": attr.label_list(
        doc = "source files, typically .ts files in the source tree",
        allow_files = True,
        mandatory = True,
    ),
    "args": attr.string_list(
        doc = "additional arguments to pass to swc cli, see https://swc.rs/docs/usage/cli",
    ),
    "source_maps": attr.string(
        doc = "see https://swc.rs/docs/usage/cli#--source-maps--s",
        values = ["true", "false", "inline", "both"],
        default = "false",
    ),
    "output_dir": attr.bool(
        doc = "whether to produce a directory output rather than individual files",
    ),
    "data": attr.label_list(
        doc = "runtime dependencies propagated to binaries that depend on this",
        allow_files = True,
    ),
    "swcrc": attr.label(
        doc = "label of a configuration file for swc, see https://swc.rs/docs/configuration/swcrc",
        allow_single_file = True,
        mandatory = True,
    ),
    "out_dir": attr.string(
        doc = "base directory for output files",
    ),
}

_outputs = {
    "js_outs": attr.output_list(doc = """list of expected JavaScript output files.

There must be one for each entry in srcs, and in the same order."""),
    "map_outs": attr.output_list(doc = """list of expected source map output files.

Can be empty, meaning no source maps should be produced.
If non-empty, there must be one for each entry in srcs, and in the same order."""),
}

_SUPPORTED_EXTENSIONS = [".ts", ".tsx", ".jsx", ".mjs", ".cjs", ".js"]

def _is_supported_src(src):
    return paths.split_extension(src)[-1] in _SUPPORTED_EXTENSIONS

def _declare_outputs(ctx, paths):
    return [ctx.actions.declare_file(p) for p in paths]

# TODO: aspect_bazel_lib should provide this?
def _relative_to_package(path, ctx):
    for prefix in (ctx.bin_dir.path, ctx.label.package):
        prefix += "/"
        if path.startswith(prefix):
            path = path[len(prefix):]
    return path

def _calculate_js_outs(srcs, out_dir = None):
    if out_dir == None:
        js_srcs = []
        for src in srcs:
            if paths.split_extension(src)[-1] == ".js":
                js_srcs.append(src)
        if len(js_srcs) > 0:
            fail("Detected swc rule with srcs=[{}, ...] and out_dir=None. Please set out_dir when compiling .js files.".format(", ".join(js_srcs[:3])))

    js_outs = [paths.replace_extension(f, ".js") for f in srcs if _is_supported_src(f)]
    if out_dir != None:
        js_outs = [paths.join(out_dir, f) for f in js_outs]

    return js_outs

def _calculate_map_outs(srcs, source_maps):
    if source_maps in ["false", "inline"]:
        return []
    return [paths.replace_extension(f, ".js.map") for f in srcs if _is_supported_src(f)]

def _impl(ctx):
    outputs = []
    binary = ctx.toolchains["@aspect_rules_swc//swc:toolchain_type"].swcinfo.swc_binary
    args = ctx.actions.args()
    args.add("compile")

    # Add user specified arguments *before* rule supplied arguments
    args.add_all(ctx.attr.args)
    args.add_all(["--source-maps", ctx.attr.source_maps])

    if ctx.attr.output_dir:
        if len(ctx.attr.srcs) != 1:
            fail("Under output_dir, there must be a single entry in srcs")
        if not ctx.files.srcs[0].is_directory:
            fail("Under output_dir, the srcs must be directories, not files")
        out = ctx.actions.declare_directory(ctx.label.name)
        outputs.append(out)
        args.add_all([
            ctx.files.srcs[0].path,
            "--out-dir",
            out.path,
            #"--no-swcrc",
            #"-q",
        ])

        ctx.actions.run(
            inputs = ctx.files.srcs + ctx.toolchains["@aspect_rules_swc//swc:toolchain_type"].swcinfo.tool_files,
            arguments = [args],
            outputs = [out],
            executable = binary,
            progress_message = "Transpiling with swc %s" % ctx.label,
        )

    else:
        srcs = [_relative_to_package(src.path, ctx) for src in ctx.files.srcs]

        if len(ctx.attr.js_outs):
            js_outs = ctx.outputs.js_outs
        else:
            js_outs = _declare_outputs(ctx, _calculate_js_outs(srcs, ctx.attr.out_dir))
        if len(ctx.attr.map_outs):
            map_outs = ctx.outputs.map_outs
        else:
            map_outs = _declare_outputs(ctx, _calculate_map_outs(srcs, ctx.attr.source_maps))
        outputs.extend(js_outs)
        outputs.extend(map_outs)
        for i, src in enumerate(ctx.files.srcs):
            src_args = ctx.actions.args()

            js_out = js_outs[i]
            inputs = [src] + ctx.toolchains["@aspect_rules_swc//swc:toolchain_type"].swcinfo.tool_files
            outs = [js_out]
            if ctx.attr.source_maps in ["true", "both"]:
                outs.append(map_outs[i])
                src_args.add_all([
                    "--source-maps-target",
                    map_outs[i].path,
                ])

            swcrc_path = ctx.file.swcrc.path
            swcrc_directory = paths.dirname(swcrc_path)
            src_args.add_all([
                "--config-file",
                swcrc_path,
            ])
            inputs.append(copy_file_to_bin_action(ctx, ctx.file.swcrc))

            src_args.add_all([
                # src.path,
                "--out-file",
                js_out.path,
                #"-q",
            ])

            ctx.actions.run_shell(
                inputs = inputs,
                arguments = [
                    args,
                    src_args,
                    "--filename",
                    src.path,
                ],
                outputs = outs,
                # Workaround swc cli bug:
                # https://github.com/swc-project/swc/blob/main/crates/swc_cli/src/commands/compile.rs#L241-L254
                # under Bazel it will think there's no tty and so it always errors here
                # https://github.com/swc-project/swc/blob/main/crates/swc_cli/src/commands/compile.rs#L301
                command = binary + " $@ < " + src.path,
                mnemonic = "SWCTranspile",
                progress_message = "Transpiling with swc %s [swc %s]" % (
                    ctx.label,
                    src.path,
                ),
            )

    # See https://docs.bazel.build/versions/main/skylark/rules.html#runfiles
    runfiles = ctx.runfiles(files = outputs + ctx.files.data)
    runfiles = runfiles.merge_all([d[DefaultInfo].default_runfiles for d in ctx.attr.data])

    providers = [
        DefaultInfo(
            files = depset(outputs),
            runfiles = runfiles,
        ),
    ]

    return providers

swc = struct(
    implementation = _impl,
    attrs = dict(_attrs, **_outputs),
    toolchains = ["@aspect_rules_swc//swc:toolchain_type"],
    SUPPORTED_EXTENSIONS = _SUPPORTED_EXTENSIONS,
    calculate_js_outs = _calculate_js_outs,
    calculate_map_outs = _calculate_map_outs,
)
