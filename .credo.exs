%{
  configs: [
    %{
      name: "default",
      strict: true,
      checks: [
        {Credo.Check.Readability.ModuleDoc, []},
        {Credo.Check.Readability.Specs, []},
        {Credo.Check.Warning.IoInspect, []},
        {Credo.Check.Warning.IExPry, []}
      ]
    }
  ]
}
