import python
from python import Python, PythonObject

# Read a file into a Mojo string
fn read_file(path: String) raises -> String:
    var f = open(path, "r")
    var contents = f.read()
    f.close()
    return String(contents)

# Map Minecraft protocol types -> Java types
fn map_type(proto_type: String) -> String:
    if proto_type == "varint":
        return "int"
    elif proto_type == "string":
        return "String"
    elif proto_type == "bool":
        return "boolean"
    elif proto_type == "uuid":
        return "java.util.UUID"
    elif proto_type == "ushort":
        return "int"
    elif proto_type == "byte_array":
        return "byte[]"
    elif proto_type == "bitfield":
        return "int"
    else:
        return "Object"

# Generate Java class code
fn generate_class(
    name: String,
    fields: List[(String, String)],
    class_template: String,
    field_template: String
) -> String:
    var field_str = ""
    for (fname, ftype) in fields:
        var tmp = field_template
        tmp = tmp.replace("{{Type}}", ftype)
        tmp = tmp.replace("{{Name}}", fname)
        field_str += tmp + "\n"

    var result = class_template
    result = result.replace("{{ClassName}}", name)
    result = result.replace("{{Fields}}", field_str)
    return result

fn parse_field(name: String, field_type: PythonObject) raises -> List[(String, String)]:
    var result = List[(String, String)]()
    var builtins = Python.import_module("builtins")

    # primitive type
    if builtins.isinstance(field_type, builtins.str):
        result.append((name, map_type(String(field_type))))

    # container array: ["container", [fields...]]
    elif builtins.isinstance(field_type, builtins.list):
        if String(field_type[0]) == "container":
            var fields_list = field_type[1]
            for f in fields_list:
                var fname = f.get("name") if "name" in f else "anon"
                result += parse_field(String(fname), f.get("type"))
        elif String(field_type[0]) == "switch":
            var switch_data = field_type[1]
            # handle each branch recursively
            for branch_key in switch_data["fields"]:
                var branch_type = switch_data["fields"][branch_key]
                result += parse_field(name + "_" + String(branch_key), branch_type)
        else:
            # fallback for unknown array types
            result.append((name, "Object"))

    # dict type
    elif builtins.isinstance(field_type, builtins.dict):
        # container dict with "type" == "container"
        if field_type.get("type") == "container":
            for f in field_type.get("fields"):
                var fname = f.get("name") if f.has_key("name") else "anon"
                result += parse_field(String(fname), f.get("type"))
        else:
            result.append((name, "Object"))

    else:
        result.append((name, "Object"))

    return result


fn main() raises:
    var allowed_types = List[String]("slot", "position", "itemStack", "bool")

    var os = Python.import_module("os")
    var builtins = Python.import_module("builtins")
    var urllib = Python.import_module("urllib.request")
    var json = Python.import_module("json")

    # Load templates
    var class_template = read_file("templates/types/type_template.java.txt")
    var field_template = read_file("templates/types/field_template.java.txt")

    # Prepare output folder
    var out_dir = "generated/types"
    os.makedirs(out_dir, exist_ok=True)

    # Fetch protocol.json
    var url = "https://raw.githubusercontent.com/PrismarineJS/minecraft-data/master/data/pc/1.19/protocol.json"
    var response = urllib.urlopen(url)
    var contents = response.read().decode("utf-8")
    response.close()
    var protocol = json.loads(contents)

    var types = protocol.get("types")

    for type_name in types:
        var type_name_str = String(type_name)
        var t = types.get(type_name)

        # Skip if not in allowed types
        var skip = True
        for allowed in allowed_types:
            if allowed == type_name_str:
                skip = False
                break
        if skip:
            continue

        var fields = List[(String, String)]()

        # Container type
        if builtins.hasattr(t, "get") and t.get("type") == "container":
            var fields_list = t.get("fields")
            for field in fields_list:
                if builtins.hasattr(field, "get"):
                    fields += parse_field(String(field.get("name")), field.get("type"))
        # Array-style container: ["container", [...]] etc.
        elif builtins.isinstance(t, builtins.list):
            fields += parse_field(type_name_str, t)
        else:
            # Non-container / primitive type -> single field called 'value'
            fields.append(("value", map_type(type_name_str)))

        # Generate class
        var java_code = generate_class(type_name_str, fields, class_template, field_template)
        var file_path = out_dir + "/" + type_name_str + ".java"
        var f = open(file_path, "w")
        f.write(java_code)
        f.close()
        print("✅ Generated:", file_path)

