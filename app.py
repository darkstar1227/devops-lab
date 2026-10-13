from fastapi import FastAPI

app = FastAPI()


@app.get("/")
def root():
    return {"message": "Hello from a chiselled Ubuntu rock"}


@app.get("/healthz")
def healthz():
    return {"status": "ok"}
