import argparse

parser = argparse.ArgumentParser()
parser.add_argument("command", choices=("list", "show"))
parser.parse_args()
