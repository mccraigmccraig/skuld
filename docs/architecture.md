# Architecture

Skuld uses evidence-passing style where:

1. **Handlers** are stored in the environment as functions
2. **Effects** look up their handler and call it directly
3. **CPS** enables control effects (Yield, Throw) to manipulate continuations
4. **Scoped handlers** automatically manage handler installation/cleanup

## Comparison with Freyja

Skuld was built after [Freyja](https://github.com/mccraigmccraig/freyja) proved to
have significant limitations, including performance issues and requiring two monad
types (`Freer` and `Hefty`), with all the additional complexity and mental load
that imposes. Skuld's client API looks quite similar to Freyja, but the implementation
is very different - Skuld performs better and has a simpler, more coherent API.

| Aspect                | Freyja                       | Skuld                |
|-----------------------|------------------------------|----------------------|
| Effect representation | Freer monad + Hefty algebras | Evidence-passing CPS |
| Computation types     | `Freer` + `Hefty`            | Just `computation`   |
| Control effects       | Hefty (higher-order)         | Direct CPS           |
| Handler lookup        | Search through handler list  | Direct map lookup    |
| Macro system          | `con` + `hefty`              | Single `comp`        |

Skuld's performance advantage comes from avoiding Freer monad object allocation,
continuation queue management, and linear search for handlers.
