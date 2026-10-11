import json
import os
import sys

print(json.dumps([dict(os.environ), sys.argv[1:]]))
