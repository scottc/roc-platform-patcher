app [main!] {
    pf: platform "../patched/main.roc",
}

import pf.Stdout
import pf.Stderr

main! = |_| {
    Stdout.line!("rpp smoke: allocating…")?

    var $i = 0.U64
    var $acc = 0.U64

    while $i < 20_000 {
        # list alloc / free
        xs = List.repeat($i, 32)
        $acc = $acc + List.len(xs)

        # string alloc / free
        s = "item-${$i.to_str()}-xxxxxxxx"
        $acc = $acc + Str.count_utf8_bytes(s)

        $i = $i + 1
    }

    Stdout.line!("acc=${$acc.to_str()}")?
    Stderr.line!("(app done; host should dump rpp counters next)")?
    Ok({})
}
