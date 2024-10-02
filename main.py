import os
import yaml

CONFIGURATION_FILE = os.path.join(os.path.dirname(__file__), "config.yaml")
configuration = yaml.safe_load(open(CONFIGURATION_FILE))

def main():
    print(configuration)


if __name__ == "__main__":
    main()
