# Used by "mix format"
[
  import_deps: [],
  plugins: [],
  heex_line_length: 80,
  locals_without_parens: [
    attr: 2,
    attr: 3,
    def_op: 1,
    def_op_struct: :*,
    def_tagged_op: 1,
    defport: :*
  ],
  inputs: [
    "{mix,.formatter}.exs",
    "*.{heex,ex,exs}",
    "priv/*/seeds.exs",
    "priv/*/seeds/**/*.{ex,exs}",
    "priv/*/data_migrations/**/*.{ex,exs}",
    "storybook/**/*.exs",
    "{_dev,config,lib,test}/**/*.{heex,ex,exs}"
  ]
]
