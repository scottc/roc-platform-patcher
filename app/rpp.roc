app [main!] {
    pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
}

import pf.Stdout
import pf.Stderr
import pf.Cmd
import pf.Path
import pf.OsStr

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

Config : {
    input : Str,
    output_dir : Str,
    work_dir : Str,
    target : Str,
    hooks : Bool,
}

default_config : Config
default_config = {
    input: "GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
    output_dir: "patched",
    work_dir: ".rpp-work",
    target: "x64musl",
    hooks: True,
}

hook_symbols : List(Str)
hook_symbols = [
    "roc_alloc",
    "roc_dealloc",
    "roc_realloc",
]

# ---------------------------------------------------------------------------
# Entry
# ---------------------------------------------------------------------------

main! : List(OsStr) => Try({}, _)
main! = |args| {
    config = parse_args(args)

    Stdout.line!("roc-platform-patcher (rpp) v0")?
    Stdout.line!("  input:  ${config.input}")?
    Stdout.line!("  target: ${config.target}")?
    Stdout.line!("  work:   ${config.work_dir}")?
    Stdout.line!("  out:    ${config.output_dir}")?

    unpack!(config)?
    symbols = inspect!(config)?
    rename_originals!(config, symbols)?
    generate_proxies!(config, symbols)?
    rebuild!(config, symbols)?
    write_metadata!(config, symbols)?
    repack!(config)?

    Stdout.line!("")?
    Stdout.line!("Done. Point an app at: ${config.output_dir}/")?
    Stdout.line!("Treat the result as a debug build.")?

    Ok({})
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

parse_args : List(OsStr) -> Config
parse_args = |args| {
    List.fold(
        args,
        default_config,
        |cfg, arg| {
            s = os_to_str(arg)
            if starts_with(s, "--input=") {
                { ..cfg, input: drop_prefix(s, "--input=") }
            } else if starts_with(s, "--output-dir=") {
                { ..cfg, output_dir: drop_prefix(s, "--output-dir=") }
            } else if starts_with(s, "--target=") {
                { ..cfg, target: drop_prefix(s, "--target=") }
            } else if s == "--hooks=false" {
                { ..cfg, hooks: False }
            } else {
                cfg
            }
        },
    )
}

# ---------------------------------------------------------------------------
# 1) Unpack
# ---------------------------------------------------------------------------

unpack! : Config => Try({}, _)
unpack! = |config| {
    Stdout.line!("[1/6] unpack")?

    run_ok!(Cmd.new("rm").args([OsStr.from_str("-rf"), OsStr.from_str(config.work_dir)]))?
    run_ok!(Cmd.new("mkdir").args([OsStr.from_str("-p"), OsStr.from_str(config.work_dir)]))?

    # tar -xf input -C work  (needs tar with zstd, or use the sh fallback)
    tar_cmd =
        Cmd.new("tar").args([
            OsStr.from_str("-xf"),
            OsStr.from_str(config.input),
            OsStr.from_str("-C"),
            OsStr.from_str(config.work_dir),
        ])

    match tar_cmd.run!() {
        Ok(out) =>
            match out.status {
                Exited(0) => Ok({})
                _ => unpack_via_zstd!(config)
            }
        Err(_) => unpack_via_zstd!(config)
    }?
    Ok({})
}

unpack_via_zstd! : Config => Try({}, _)
unpack_via_zstd! = |config| {
    script = "zstd -dc '${config.input}' | tar -xf - -C '${config.work_dir}'"
    run_ok!(Cmd.new("sh").args([OsStr.from_str("-c"), OsStr.from_str(script)]))
}

# ---------------------------------------------------------------------------
# 2) Inspect
# ---------------------------------------------------------------------------

inspect! : Config => Try(List(Str), _)
inspect! = |config| {
    Stdout.line!("[2/6] inspect symbols")?

    libhost = "${config.work_dir}/targets/${config.target}/libhost.a"
    ensure_file!(libhost)?

    nm_out = try_nm!(libhost)?

    lines = split_lines(nm_out)
    symbols =
        lines
            |> List.keep_if(|line| contains(line, " T ") or contains(line, " t "))
            |> List.map(|line| last_token(line))
            |> List.keep_if(|name| Str.count_utf8_bytes(name) > 0)
            |> unique_strings

    count_str = num_to_str(List.len(symbols))
    Stdout.line!("  found ${count_str} text symbols in libhost.a")?

    Path.write_utf8!("${config.work_dir}/symbols.txt", Str.join_with(symbols, "\n"))?

    hooked = List.keep_if(hook_symbols, |s| list_contains(symbols, s))
    Stdout.line!("  hookable: ${Str.join_with(hooked, ", ")}")?
    Ok(symbols)
}

try_nm! : Str => Try(Str, _)
try_nm! = |archive| {
    match Cmd.new("llvm-nm").args([OsStr.from_str("-g"), OsStr.from_str(archive)]).run!() {
        Ok(out) =>
            match out.status {
                Exited(0) => Ok(utf8_lossy(out.stdout_bytes))
                _ => nm_fallback!(archive)
            }
        Err(_) => nm_fallback!(archive)
    }
}

nm_fallback! : Str => Try(Str, _)
nm_fallback! = |archive| {
    out = Cmd.new("nm").args([OsStr.from_str("-g"), OsStr.from_str(archive)]).run!()?
    match out.status {
        Exited(0) => Ok(utf8_lossy(out.stdout_bytes))
        Exited(code) => {
            Stderr.line!("nm failed (${code.to_str()}) on ${archive}")?
            Err(Exit(1))
        }
        Signaled(_) => Err(Exit(1))
    }
}

# ---------------------------------------------------------------------------
# 3) Rename originals
# ---------------------------------------------------------------------------

rename_originals! : Config, List(Str) => Try({}, _)
rename_originals! = |config, all_symbols| {
    Stdout.line!("[3/6] rename originals")?

    if !config.hooks {
        Stdout.line!("  hooks disabled; skip rename")?
        return Ok({})
    }

    extract_dir = "${config.work_dir}/extract"
    run_ok!(Cmd.new("rm").args([OsStr.from_str("-rf"), OsStr.from_str(extract_dir)]))?
    run_ok!(Cmd.new("mkdir").args([OsStr.from_str("-p"), OsStr.from_str(extract_dir)]))?

    extract_script =
        "cd '${extract_dir}' && ar x '../targets/${config.target}/libhost.a'"
    run_ok!(Cmd.new("sh").args([OsStr.from_str("-c"), OsStr.from_str(extract_script)]))?

    to_hook = List.keep_if(hook_symbols, |s| list_contains(all_symbols, s))

    if List.len(to_hook) == 0 {
        Stderr.line!("  warning: none of the known hook symbols were found")?
        return Ok({})
    }

    # --redefine-sym=roc_alloc=roc_alloc_orig ...
    redefine =
        to_hook
            |> List.map(|s| "--redefine-sym=${s}=${s}_orig")
            |> Str.join_with(" ")

    rename_script =
        "set -e; cd '${extract_dir}'; for f in *.o; do [ -f \"\$f\" ] || continue; if command -v llvm-objcopy >/dev/null 2>&1; then llvm-objcopy ${redefine} \"\$f\" \"\$f\"; else objcopy ${redefine} \"\$f\" \"\$f\"; fi; done"

    run_ok!(Cmd.new("sh").args([OsStr.from_str("-c"), OsStr.from_str(rename_script)]))?
    Stdout.line!("  redefined: ${Str.join_with(to_hook, ", ")}")?
    Ok({})
}

# ---------------------------------------------------------------------------
# 4) Generate C proxies
# ---------------------------------------------------------------------------

generate_proxies! : Config, List(Str) => Try({}, _)
generate_proxies! = |config, all_symbols| {
    Stdout.line!("[4/6] generate proxies")?

    if !config.hooks {
        Stdout.line!("  hooks disabled; skip proxies")?
        return Ok({})
    }

    to_hook = List.keep_if(hook_symbols, |s| list_contains(all_symbols, s))
    src = emit_proxy_c(to_hook)
    Path.write_utf8!("${config.work_dir}/rpp_proxies.c", src)?
    Stdout.line!("  wrote rpp_proxies.c")?
    Ok({})
}

emit_proxy_c = |symbols| {
    header =
        "#include <stdint.h>\n#include <stddef.h>\n#include <stdlib.h>\n#include <string.h>\n#include <unistd.h>\n#include <fcntl.h>\n#include <time.h>\n\ntypedef struct {\n    uint64_t calls;\n    uint64_t total_ns;\n} rpp_counter_t;\n\nstatic void rpp_maybe_flush(void);\nstatic void rpp_flush_stats(void);\n\nstatic uint64_t rpp_now_ns(void) {\n    struct timespec ts;\n    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) return 0;\n    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;\n}\n\nstatic void rpp_write_str(const char *s) {\n    if (!s) return;\n    size_t n = 0;\n    while (s[n]) n++;\n    (void)write(2, s, n);\n}\n\nstatic void rpp_write_u64(uint64_t v) {\n    char buf[32];\n    int i = 30;\n    buf[31] = '\\0';\n    if (v == 0) { buf[i--] = '0'; }\n    else {\n        while (v > 0 && i >= 0) {\n            buf[i--] = (char)('0' + (v % 10));\n            v /= 10;\n        }\n    }\n    rpp_write_str(&buf[i + 1]);\n}\n\nstatic void rpp_dump_one(const char *name, const rpp_counter_t *c) {\n    rpp_write_str(\"[rpp] \");\n    rpp_write_str(name);\n    rpp_write_str(\" calls=\");\n    rpp_write_u64(c->calls);\n    rpp_write_str(\" total_ns=\");\n    rpp_write_u64(c->total_ns);\n    rpp_write_str(\"\\n\");\n}\n\nstatic const char *rpp_stats_path(void) {\n    const char *p = getenv(\"RPP_STATS_PATH\");\n    return (p && p[0]) ? p : \".rpp-stats.json\";\n}\n\nstatic void rpp_write_u64_fd(int fd, uint64_t v) {\n    char buf[32];\n    int i = 30;\n    buf[31] = '\\0';\n    if (v == 0) { buf[i--] = '0'; }\n    else {\n        while (v > 0 && i >= 0) {\n            buf[i--] = (char)('0' + (v % 10));\n            v /= 10;\n        }\n    }\n    const char *s = &buf[i + 1];\n    size_t n = 0;\n    while (s[n]) n++;\n    (void)write(fd, s, n);\n}\n\nstatic void rpp_write_str_fd(int fd, const char *s) {\n    if (!s) return;\n    size_t n = 0;\n    while (s[n]) n++;\n    (void)write(fd, s, n);\n}\n\n"

    body =
        List.fold(
            symbols,
            "",
            |acc, name| Str.concat(acc, emit_one_proxy(name)),
        )

    dump_lines =
        List.fold(
            symbols,
            "",
            |acc, name| Str.concat(acc, "    rpp_dump_one(\"${name}\", &rpp_cnt_${name});\n"),
        )

    flush_body = emit_flush_json(symbols)

    footer =
        "static void rpp_dump_all(void) {\n${dump_lines}}\n\n${flush_body}\nstatic uint64_t rpp_last_flush_ns = 0;\n\nstatic void rpp_maybe_flush(void) {\n    uint64_t now = rpp_now_ns();\n    if (rpp_last_flush_ns != 0 && (now - rpp_last_flush_ns) < 500000000ull) return;\n    rpp_last_flush_ns = now;\n    rpp_flush_stats();\n}\n\nstatic void rpp_init(void) {\n    atexit(rpp_dump_all);\n    atexit(rpp_flush_stats);\n    rpp_flush_stats();\n}\n\n__attribute__((constructor)) static void rpp_ctor(void) {\n    rpp_init();\n}\n"

    Str.concat(header, Str.concat(body, footer))
}

emit_flush_json = |symbols| {
    open =
        "static void rpp_flush_stats(void) {\n    const char *path = rpp_stats_path();\n    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);\n    if (fd < 0) return;\n    rpp_write_str_fd(fd, \"{\");\n"

    middle =
        List.fold(
            symbols,
            { text: "", first: True },
            |st, name| {
                prefix =
                    if st.first {
                        ""
                    } else {
                        "    rpp_write_str_fd(fd, \",\");\n"
                    }

                chunk =
                    "${prefix}    rpp_write_str_fd(fd, \"\\\"${name}\\\":{\\\"calls\\\":\");\n    rpp_write_u64_fd(fd, rpp_cnt_${name}.calls);\n    rpp_write_str_fd(fd, \",\\\"total_ns\\\":\");\n    rpp_write_u64_fd(fd, rpp_cnt_${name}.total_ns);\n    rpp_write_str_fd(fd, \"}\");\n"

                {
                    text: Str.concat(st.text, chunk),
                    first: False,
                }
            },
        )

    close =
        "    rpp_write_str_fd(fd, \"}\\n\");\n    close(fd);\n}\n"

    Str.concat(open, Str.concat(middle.text, close))
}

emit_one_proxy = |name| {
    match name {
        "roc_alloc" =>
            "extern void *roc_alloc_orig(size_t size, uint32_t alignment);\nrpp_counter_t rpp_cnt_roc_alloc = {0, 0};\nvoid *roc_alloc(size_t size, uint32_t alignment) {\n    uint64_t t0 = rpp_now_ns();\n    void *p = roc_alloc_orig(size, alignment);\n    rpp_cnt_roc_alloc.total_ns += rpp_now_ns() - t0;\n    rpp_cnt_roc_alloc.calls += 1;\n    rpp_maybe_flush();\n    return p;\n}\n\n"

        "roc_dealloc" =>
            "extern void roc_dealloc_orig(void *ptr, uint32_t alignment);\nrpp_counter_t rpp_cnt_roc_dealloc = {0, 0};\nvoid roc_dealloc(void *ptr, uint32_t alignment) {\n    uint64_t t0 = rpp_now_ns();\n    roc_dealloc_orig(ptr, alignment);\n    rpp_cnt_roc_dealloc.total_ns += rpp_now_ns() - t0;\n    rpp_cnt_roc_dealloc.calls += 1;\n    rpp_maybe_flush();\n}\n\n"

        "roc_realloc" =>
            "extern void *roc_realloc_orig(void *ptr, size_t new_size, size_t old_size, uint32_t alignment);\nrpp_counter_t rpp_cnt_roc_realloc = {0, 0};\nvoid *roc_realloc(void *ptr, size_t new_size, size_t old_size, uint32_t alignment) {\n    uint64_t t0 = rpp_now_ns();\n    void *p = roc_realloc_orig(ptr, new_size, old_size, alignment);\n    rpp_cnt_roc_realloc.total_ns += rpp_now_ns() - t0;\n    rpp_cnt_roc_realloc.calls += 1;\n    rpp_maybe_flush();\n    return p;\n}\n\n"

        _ =>
            "/* unsupported symbol: ${name} */\n"
    }
}

# ---------------------------------------------------------------------------
# 5) Rebuild
# ---------------------------------------------------------------------------

rebuild! : Config, List(Str) => Try({}, _)
rebuild! = |config, _all_symbols| {
    if !config.hooks {
        Stdout.line!("  hooks disabled; skip rebuild")?
        return Ok({})
    }

    extract_dir = "${config.work_dir}/extract"
    proxy_c = "${config.work_dir}/rpp_proxies.c"
    proxy_o = "${extract_dir}/rpp_proxies.o"
    # path to libhost.a *from extract_dir*
    new_a_rel = "../targets/${config.target}/libhost.a"

    compile_script =
        "set -e; if command -v clang >/dev/null 2>&1; then CC=clang; else CC=cc; fi; \$CC -c -O2 -fPIC -o '${proxy_o}' '${proxy_c}'"
    run_ok!(Cmd.new("sh").args([OsStr.utf8("-c"), OsStr.utf8(compile_script)]))?

    archive_script =
        "set -e; cd '${extract_dir}'; rm -f '${new_a_rel}'; if command -v llvm-ar >/dev/null 2>&1; then llvm-ar rcs '${new_a_rel}' *.o; else ar rcs '${new_a_rel}' *.o; fi"
    run_ok!(Cmd.new("sh").args([OsStr.utf8("-c"), OsStr.utf8(archive_script)]))?

    Stdout.line!("  wrote ${config.work_dir}/targets/${config.target}/libhost.a")?
    Ok({})
}

# ---------------------------------------------------------------------------
# 6) Metadata + repack
# ---------------------------------------------------------------------------

write_metadata! : Config, List(Str) => Try({}, _)
write_metadata! = |config, symbols| {
    Stdout.line!("[6a] metadata")?

    n = num_to_str(List.len(symbols))
    hooks_json = if config.hooks {
        "true"
    } else {
        "false"
    }
    json =
        "{\"tool\":\"roc-platform-patcher\",\"target\":\"${config.target}\",\"hooks\":${hooks_json},\"text_symbol_count\":${n}}\n"

    Path.write_utf8!("${config.work_dir}/rpp-status.json", json)?

    readme =
        "# Patched Roc platform (rpp)\n\nDebug build. Proxies count roc_alloc/dealloc/realloc and print stats on stderr at exit.\n"
    Path.write_utf8!("${config.work_dir}/RPP_README.md", readme)?
    Ok({})
}

repack! : Config => Try({}, _)
repack! = |config| {
    Stdout.line!("[6b] repack → ${config.output_dir}")?

    run_ok!(Cmd.new("rm").args([OsStr.from_str("-rf"), OsStr.from_str(config.output_dir)]))?
    run_ok!(Cmd.new("mkdir").args([OsStr.from_str("-p"), OsStr.from_str(config.output_dir)]))?

    copy_script =
        "set -e; if [ -d '${config.work_dir}/targets' ]; then cp -a '${config.work_dir}/.' '${config.output_dir}/'; else top=\$(find '${config.work_dir}' -mindepth 1 -maxdepth 1 -type d | head -n1); cp -a \"\$top/.\" '${config.output_dir}/'; fi"
    run_ok!(Cmd.new("sh").args([OsStr.from_str("-c"), OsStr.from_str(copy_script)]))?

    Stdout.line!("  platform ready at ${config.output_dir}/")?
    Ok({})
}

# ---------------------------------------------------------------------------
# Cmd helper
# ---------------------------------------------------------------------------

run_ok! = |cmd| {
    out = cmd.run!()?
    match out.status {
        Exited(0) => Ok({})
        Exited(code) => {
            Stderr.line!("command failed (${code.to_str()})")?
            err_text = utf8_lossy(out.stderr_bytes)
            if Str.count_utf8_bytes(err_text) > 0 {
                Stderr.line!(err_text)?
            }
            Err(Exit(code))
        }
        Signaled(_) => {
            Stderr.line!("command signaled")?
            Err(Exit(1))
        }
    }
}

ensure_file! : Str => Try({}, _)
ensure_file! = |path| {
    out = Cmd.new("test").args([OsStr.from_str("-f"), OsStr.from_str(path)]).run!()?
    match out.status {
        Exited(0) => Ok({})
        _ => {
            Stderr.line!("missing file: ${path}")?
            Stderr.line!("  (check --target; expected targets/<target>/libhost.a)")?
            Err(Exit(1))
        }
    }
}

# ---------------------------------------------------------------------------
# Pure helpers (no effectful !)
# ---------------------------------------------------------------------------

os_to_str : OsStr -> Str
os_to_str = |os| {
    os.display()
}

starts_with : Str, Str -> Bool
starts_with = |s, prefix| {
    Str.starts_with(s, prefix)
}

drop_prefix : Str, Str -> Str
drop_prefix = |s, prefix| Str.drop_prefix(s, prefix)

contains : Str, Str -> Bool
contains = |hay, needle| {
    Str.contains(hay, needle)
}

split_lines : Str -> List(Str)
split_lines = |s| {
    Str.split_on(s, "\n")
}

last_token : Str -> Str
last_token = |line| {
    parts =
        Str.split_on(line, " ")
            |> List.keep_if(|p| Str.count_utf8_bytes(p) > 0)
    match List.last(parts) {
        Ok(tok) => tok
        Err(_) => ""
    }
}

unique_strings : List(Str) -> List(Str)
unique_strings = |xs| {
    List.fold(
        xs,
        [],
        |acc, x| {
            if list_contains(acc, x)
                acc
            else
                List.append(acc, x)
        },
    )
}

list_contains : List(Str), Str -> Bool
list_contains = |xs, x| {
    List.any(xs, |y| y == x)
}

num_to_str : U64 -> Str
num_to_str = |n| {
    n.to_str()
}

utf8_lossy : List(U8) -> Str
utf8_lossy = |bytes| {
    match Str.from_utf8(bytes) {
        Ok(s) => s
        Err(_) => "<binary>"
    }
}
