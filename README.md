# Tact

## Building from source

* Install `opam` using this [guide](https://ocaml.org/learn/tutorials/up_and_running.html)
* Run following commands:
```
opam init
opam switch create $(pwd) -y
eval $(opam env)
dune build && dune install
```

You can now use `tact /path/to/file.tact`

### Updating dependencies

Run `opam install tact --working-dir`

### Running REPL

Run `dune utop`

### Running tests

Run `dune test`

