app [main!] {
    pf: platform "../patched/main.roc",
}

import pf.Stdout

main! = |_| {
    Stdout.line!("rpp long-run: stats → $RPP_STATS_PATH or .rpp-stats.json")?
    Stdout.line!("Ctrl-C to stop (atexit dump on stderr)")?

    var $i = 0.U64
    var $acc = 0.U64

    while True {
        var $j = 0.U64
        while $j < 2000 {
            xs = List.repeat($i, 24)
            s = "tick-${$i.to_str()}-${$j.to_str()}"
            $acc = $acc + List.len(xs) + Str.count_utf8_bytes(s)
            $j = $j + 1
        }

        $i = $i + 1
        if $i % 50 == 0 {
            Stdout.line!("still running i=${$i.to_str()} acc=${$acc.to_str()}")?
        }
    }

    Ok({})
}
