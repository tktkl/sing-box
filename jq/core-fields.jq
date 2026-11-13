# Field names are data from official Go option patches, never shell input.
def fields($prefix):
  [.files[] | select(.filename|test("^option/.*\\.go$")) | . as $file |
    (.patch//""|split("\n")[]) |
    select(startswith($prefix) and (startswith($prefix+$prefix+$prefix)|not)) |
    try capture("json:\"(?<field>[A-Za-z_][A-Za-z0-9_-]*)") |
    {file:$file.filename,field:.field}] | unique;
fields("+") as $added | fields("-") as $removed |
{status:(if (.files|length)>=300 or any(.files[];(.filename|test("^option/.*\\.go$")) and .patch==null) then "partial" else "complete" end),
 source:$source,added:($added-$removed),removed:($removed-$added)}
