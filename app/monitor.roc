app [main!] {
    pf: platform "https://github.com/roc-lang/basic-cli/releases/download/0.26.0/GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst",
}

import pf.Stdout
import pf.Stderr
import pf.Path
import pf.Cmd
import pf.OsStr

main! = |args| {
    path =
        match args {
            [_, p] => os_to_str(p)
            _ => ".rpp-stats.json"
        }

    Stdout.line!("rpp monitor: watching ${path} (poll ~0.5s)")?
    Stdout.line!("start test_long in another terminal first")?

    var $prev = ""

    while True {
        match Path.read_utf8!(Path.utf8(path)) {
            Ok(text) => {
                if text != $prev {
                    Stdout.line!("── ${text}")?
                    $prev = text
                }
            }
            Err(_) => {
                Stderr.line!("(waiting for ${path})")?
            }
        }

        # same pattern as the patcher: run! not status!
        _ = Cmd.new("sleep").args([OsStr.utf8("0.5")]).run!()
    }
}

os_to_str = |os| {
    match OsStr.to_raw(os) {
        Utf8(s) => s
        _ => ".rpp-stats.json"
    }
}
