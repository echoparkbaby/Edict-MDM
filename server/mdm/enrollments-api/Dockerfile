FROM python:3.12-alpine
RUN pip install --no-cache-dir pymysql cryptography
COPY app.py /app/app.py
EXPOSE 8080
ENTRYPOINT ["python", "-u", "/app/app.py"]
