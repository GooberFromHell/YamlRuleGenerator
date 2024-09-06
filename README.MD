# YamlRuleGenerator

The YamlRuleGenerator is apowershell script configured using a yaml configuration file. 

## Usage

To use the YamlRuleGenerator, follow these steps:

1. Open the terminal and navigate to the `YamlRuleGenerator` directory.
2. Configure the `config.yaml` accoding to your needs/envrionment
2. Run the command: `Run.ps1`.

## Configuration

The YamlRuleGenerator can be configured by modifying the `config.yaml` file.

### Settings

> [!IMPORTANT]
> Configuration file if yaml formatted. Watch your indents!

#### Global
Global options for rule generation.

| Setting            | Type   | Description                                                                                                    |
| ------------------ | ------ | -------------------------------------------------------------------------------------------------------------- |
| sid_start          | Int    | This is the starting number for the SID increment when creating rules. **Can be overridden in rule templates** |
| revision           | Int    | This is the revision number applied to the end of each rule. **Can be overridden in rule templates.**          |
| ioc_directory      | String | Path to the location of your Ioc Files. The file contents could have ones Ioc per line                         |
| rules_directory    | String | Path to the location to store comleted rules and lists.                                                        |
| split_rules        | Bool   | Option to split rules into seperate rule files based on the rules type.                                        |
| add_rule_reference | Bool   | Option to add a reference to each rule of what file it was generated from                                      |

#### Templates
Templates section contains a list of rule generation objects that control the identification of an Ioc, Its output, and default values. Each generation object have the following options:
Example: The follow shows the layout of the templates object and the listed generation rules.
```yaml
templates:
  - name: ip
    regex:
      - '(?<ip>(\d{1,3}\.){3}\d{1,3})'
    template: 'alert ip {sip} {sport} -> {dip} {dport} (msg:"{msg}"; sid:{sid}; rev:{rev};)'
    required:
    - ip
    defaults:
      sip: any
      sport: any
      dip: "{ip}"
      dport: any
      msg: "Known malicious IP address detected"
  - name: tls
    lists:
      - md5
    regex:
      - "(?<ja3_hash>[a-fA-F0-9]{32})"
    template: 'alert tls {sip} {sport} -> {dip} {dport} (msg:"{msg}"; flow:established,to_server; ja3_hash; content:"{ja3_hash}"; sid:{sid}; rev:{rev};)'
    defaults:
      sip: any
      sport: any
      dip: any
      dport: any
      msg: "Known malicious hash detected"
```

#### Setting: template.name
- Type: String
- Description: Name of the item. Single word that represents the type of alert to be created.
- Example: No explaination required.
```yaml
...
name: ip
...
```

#### Setting: template.regex   
- Type: String[]
- Description: This is a list of regex string used to detect the componenets of the Ioc signature using regex capture groups. **More on this below**
- Example: The following are two different regex strings that would be used to match for a 'domain'.
```yaml
...
regex: 
- '(?:http://)?(?<domain>(\d{1,3}\.){3}\d{1,3})'
- '(?<domain>([\w-]+\.)+\w{2,})'
...
```

> [!IMPORTANT]
> Each regex string in the list must contain the same named capture groups. Each regex 
> string is stitched togeather with an `|` effectivly creating an `OR`.
> [Reference Powershell regex syntax for more information](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_regular_expressions?view=powershell-7.4)

#### Setting: template.template
- Type: String 
- Description: Template string used to generate the Suricata signature. The signature templated fields **MUST** match a name of one fo the regex named capture groups to be property replaced in the signature template string.
- Example: The following is a template for a dns rule that uses the named capture groups to fill in the rule template.
```yaml
...
template: 'alert dns {sip} {sport} -> {dip} {dport} (msg:"{msg}"; dns.query.name; content:"{domain}"; nocase; sid:{sid}; rev:{rev};)'
...
```

#### Setting: template.lists
- Type: String[]
- Description: List of file lists to add the matched content too. This feature works best when there is only one named capture group per regex pattern.
- Example: The following would add matches found to `md5.list`,`ja3.list`,`sha1.list`
```yaml
...
lists:
- md5
- ja3
- sha1
...
```

#### Setting: template.required
- Type: String[]
- Description: List of named group matches that are must be found in the given regex strings for a signature created.
- Example: The following would require that named capture groups for `domain` and `uri` are found in order to create a signature.
```yaml
...
required:
- domain
- uri
...
```

#### Setting: template.defaults
- Type: Object
- Description: Object of Key: Values pairs that will be used as defaults in the event a match for a field is not found. These will not override `required` fields.
- Example: The following values would be replaced in the rule template string as default values in the event named matches are not found. 
```yaml
...
defaults:
    sip: any
    sport: any
    dip: any
    dport: '{ip}'
    msg: "Known malicious domain detected"
...
```

> [!TIP]
> You can used named capture groups as default values as well.