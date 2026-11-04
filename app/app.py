import os

from flask import Flask, jsonify

app = Flask(__name__)


@app.route("/")
def home():
    return "Hello from platform-health-service!\n"


@app.route("/health")
def health():
    return jsonify(status="ok")


if __name__ == "__main__":
    # local dev only - in the container this runs under gunicorn
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))
