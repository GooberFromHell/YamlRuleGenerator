import re


class SignaturePattern:
    def __init__(self, pattern_dict):
        self.__dict__.update(pattern_dict)

        # Convert self.template to SignatureTemplate object
        if isinstance(self.template, str):
            self.template = SignatureTemplate(self.template)

        # Convert self.regex to list of regex objects
        if isinstance(self.regex, list):
            self.regex = [re.compile(r) for r in self.regex]


class SignatureTemplate:
    keywords = {}

    def __init__(self, template_str):
        self.action, self.protocol, self.src_ip, self.src_port, self.direction, self.dst_ip, self.dst_port = template_str.split("(")[
            0
        ].split()
        for x in template_str.split("(")[1][:-2].split(";"):
            k, v = x.split(":")
            self.keywords[k] = v


# Example usage:
pattern_dict = {
    "name": "ip",
    "regex": ["(?P<ip>(\\d{1,3}\\.){3}\\d{1,3})"],
    "template": 'alert ip {sip} {sport} -> {dip} {dport} (msg:"{msg}"; sid:{sid}; rev:{rev};)',
    "defaults": {"sip": "any", "sport": "any", "dip": "{ip}", "dport": "any", "msg": "Known malicious IP address detected"},
}

signature_pattern = SignaturePattern(pattern_dict)
