"""Shared Spark session factory wired to MinIO + Delta Lake.

Import in every notebook:
    from scripts.spark_session import get_spark
    spark = get_spark()
"""
import os

from pyspark.sql import SparkSession
from delta import configure_spark_with_delta_pip


def get_spark(app_name: str = "lakehouse-lab") -> SparkSession:
    builder = (
        SparkSession.builder.appName(app_name)
        .config("spark.sql.extensions", "io.delta.sql.DeltaSparkSessionExtension")
        .config(
            "spark.sql.catalog.spark_catalog",
            "org.apache.spark.sql.delta.catalog.DeltaCatalog",
        )
        # MinIO / S3A. Endpoint is overridable because the two container
        # runtimes reach MinIO differently: docker-compose resolves the service
        # name `minio` over its built-in DNS, while Apple's `container` has no
        # name resolution without a sudo-created DNS domain, so the native
        # runner injects MinIO's IP instead. Default keeps compose unchanged.
        .config("spark.hadoop.fs.s3a.endpoint",
                os.environ.get("MINIO_ENDPOINT", "http://minio:9000"))
        .config("spark.hadoop.fs.s3a.access.key",
                os.environ.get("MINIO_ROOT_USER", "minioadmin"))
        .config("spark.hadoop.fs.s3a.secret.key",
                os.environ.get("MINIO_ROOT_PASSWORD", "minioadmin"))
        .config("spark.hadoop.fs.s3a.path.style.access", "true")
        .config(
            "spark.hadoop.fs.s3a.impl", "org.apache.hadoop.fs.s3a.S3AFileSystem"
        )
        .config("spark.sql.shuffle.partitions", "8")
    )

    # Spark creates spark.sql.warehouse.dir eagerly and chmods it. Its default
    # is ./spark-warehouse, i.e. inside the bind mount — and under WSL2 that
    # mount is a Windows drive where chmod cannot work, so the very first query
    # dies before it runs:
    #
    #   ExitCodeException exitCode=1: chmod: changing permissions of
    #   '/workspace/spark-warehouse': Operation not permitted
    #
    # Keeping the warehouse off the mount fixes it. Nothing is lost: every table
    # in this lab is written to s3a://, so the directory only holds an empty
    # tree. Env-driven so a native (non-container) run keeps Spark's default.
    warehouse = os.environ.get("SPARK_WAREHOUSE_DIR")
    if warehouse:
        builder = builder.config("spark.sql.warehouse.dir", warehouse)

    # Ivy needs a writable dir to resolve delta-spark / hadoop-aws. Its default
    # (~/.ivy2) is not writable in the container, which kills the JVM before
    # the Py4J gateway comes up. docker-compose points this at ~/.cache/ivy.
    ivy_dir = os.environ.get("SPARK_IVY_DIR")
    if ivy_dir:
        os.makedirs(ivy_dir, exist_ok=True)
        builder = builder.config("spark.jars.ivy", ivy_dir)

    return configure_spark_with_delta_pip(
        builder,
        extra_packages=["org.apache.hadoop:hadoop-aws:3.3.4"],
    ).getOrCreate()
