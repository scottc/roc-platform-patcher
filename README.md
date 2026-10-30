# Roc platform patcher

Alter platform behaviour.

## About

Let's you patch platforms, with additional dev tools. Such as observability hooks, effects boundry instrumenting, allocation stats, call graphs, mocks, stubs, behaviour replacement, fuzzing etc.

Comes with batteries included; useful default hooks, hotswapable substitutions, mockers, fuzzers & dev tools.

## Dev Tool

An intergrated UI, that lists all of the host, platform & app symbols for monitoring, mocking function calls, hotswapping & substituting function behaviour.

## How it works

1) Give it a platform.
3) It inspects the `targets/*/libhost.a` symbols.
4) It adds proxy functions with hooks for all symbols.
5) It adds devtools which knows about the symbol information & hooks.
6) It re-bundles the platform, with the hooks & devtools.

> [!IMPORTANT]
> A patched platform, may alter the security profile & behaviour of the platform, differing from it's original intended security scope, context & behaviour.
>
> Such as an increased or decreased attack surface, which may not be suitable for some adversarial environments, such as production.
>
> The key point here, is that the platform security profile can be modified, and you should use additional discression & caution, when using modified platforms.
>
> But it's not all bad news, we can also use the same technique to harden platforms, to increase security.

## Usage Example

In this example, we've intercepted `roc-lang/basic-cli@0.26.0` `roc_alloc`, with proxy functions with monitoring hooks.

But these could be anything... noops, hot swappable dynamically loaded alternative functions, panics/crashes, additional function calls with mock data, fuzzing etc... Additional platform APIs, that apps can use... The sky is the limit...

Install dependencies:
```sh
nix run github:lukewilliamboswell/roc-blueprint/0.11.0 -- shell
```

Patch a platform, in this example we're using `roc-lang/basic-cli@0.26.0`:
```sh
roc app/rpp.roc -- \
  --input=GddgvsGjiNXrHFW6au5i5dUDbTs8FinQdrgE2Gqmw53t.tar.zst \
  --output-dir=patched \
  --target=x64musl
```

Use the patched platform:
```
# terminal A - process under test
roc app/test_long.roc

# terminal B - live monitor
roc app/monitor.roc
```
Example of intercepted roc_alloc calls with monitoring hooks output:
```
(poll ~0.5s)
── {"roc_alloc":{"calls":26451196,"total_ns":966265338},"roc_dealloc":{"calls":26450932,"total_ns":908211319},"roc_realloc":{"calls":0,"total_ns":0}}

── {"roc_alloc":{"calls":26870732,"total_ns":980522106},"roc_dealloc":{"calls":26870463,"total_ns":921647486},"roc_realloc":{"calls":0,"total_ns":0}}

── {"roc_alloc":{"calls":27301462,"total_ns":994581860},"roc_dealloc":{"calls":27301189,"total_ns":934940749},"roc_realloc":{"calls":0,"total_ns":0}}

── {"roc_alloc":{"calls":27748110,"total_ns":1008667933},"roc_dealloc":{"calls":27747832,"total_ns":948177243},"roc_realloc":{"calls":0,"total_ns":0}}

── {"roc_alloc":{"calls":28169957,"total_ns":1023112203},"roc_dealloc":{"calls":28169676,"total_ns":961872158},"roc_realloc":{"calls":0,"total_ns":0}}

── {"roc_alloc":{"calls":28516927,"total_ns":1038033782},"roc_dealloc":{"calls":28516642,"total_ns":975673305},"roc_realloc":{"calls":0,"total_ns":0}}
```

## Supported targets

- [x] x64musl (x86_64 Linux)
- [ ] ...
- [ ] ...
