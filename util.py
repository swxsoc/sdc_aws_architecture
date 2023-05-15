import os
import logging
import yaml
from aws_cdk import Tags
from datetime import datetime


logging.basicConfig(level=logging.INFO)


def load_config(config_file_path="./config.yaml"):
    """
    This function loads the config.yaml file
    """
    config = {}

    # Read YAML file and parse variables
    try:
        with open(config_file_path, "r") as f:
            loaded_config = yaml.safe_load(f)
            logging.info("config.yaml loaded successfully")
            environment = (
                "PRODUCTION"
                if os.getenv("CDK_ENVIRONMENT") == "PRODUCTION"
                else "DEVELOPMENT"
            )
            config["DEPLOYMENT_ENVIRONMENT"] = environment
            bucket_list = []
            public_ecr_repo_list = []
            private_ecr_repo_list = []
            prefix = "dev-" if environment != "PRODUCTION" else ""
            print(loaded_config)
            for key, value in loaded_config.items():
                if "TIMESTREAM_DATABASE_NAME" in key:
                    value = prefix + value
                if "TIMESTREAM_S3_LOGS_TABLE_NAME" in key:
                    value = prefix + value
                if "BUCKET_NAME" in key:
                    value = prefix + value
                    bucket_list.append(value)
                if "PUBLIC_ECR_NAME" in key:
                    value = prefix + value
                    public_ecr_repo_list.append(value)
                if "PRIVATE_ECR_NAME" in key:
                    value = prefix + value
                    private_ecr_repo_list.append(value)

                config[key] = value

            # Initialize other constants after loading YAML file
            config["INSTR_TO_BUCKET_NAME"] = [
                f"{prefix}{config['MISSION_NAME']}-{this_instr}"
                for this_instr in config["INSTR_NAMES"]
            ]
            config["BUCKET_LIST"] = bucket_list + config["INSTR_TO_BUCKET_NAME"]
            config["ECR_PUBLIC_REPO_LIST"] = public_ecr_repo_list
            config["ECR_PRIVATE_REPO_LIST"] = private_ecr_repo_list

            print(config)

    except FileNotFoundError:
        logging.error(
            "config.yaml not found. Check to make sure it exists in the root directory."
        )
        exit(1)

    return config


def validate_config(config):
    """
    This function validates the config dict.
    """
    required_keys = [
        "DEPLOYMENT_ENVIRONMENT",
        "DEPLOYMENT_REGION",
        "MISSION_NAME",
        "MISSION_PKG",
        "VALID_DATA_LEVELS",
        "INSTR_NAMES",
        "INCOMING_BUCKET_NAME",
        "SORTING_LAMBDA_BUCKET_NAME",
        "S3_SERVER_ACCESS_LOGS_BUCKET_NAME",
        "PROCESSING_LAMBDA_PRIVATE_ECR_NAME",
        "DOCKER_BASE_PUBLIC_ECR_NAME",
        "TIMESTREAM_DATABASE_NAME",
        "TIMESTREAM_S3_LOGS_TABLE_NAME",
    ]

    missing_keys = [key for key in required_keys if key not in config]

    if missing_keys:
        for key in missing_keys:
            logging.error(f"{key} not found in config.yaml")
        return False

    return True


def apply_standard_tags(construct):
    """
    This function applies the default tags to the different resources created
    """

    # Standard Purpose Tag
    Tags.of(construct).add(
        "Purpose", "SWSOC Pipeline", apply_to_launched_instances=True
    )

    # Standard Last Modified Tag
    Tags.of(construct).add("Last Modified", str(datetime.today()))

    # Environment Name
    environment_name = (
        "Production" if os.getenv("CDK_ENVIRONMENT") == "PRODUCTION" else "Development"
    )

    # Standard Environment Tag
    Tags.of(construct).add("Environment", environment_name)

    # Git Version Tag If It Exists
    if os.getenv("GIT_TAG"):
        Tags.of(construct).add("Version", os.getenv("GIT_TAG"))


def is_production(dict: dict):
    """
    This function returns True if the environment is production
    """
    return dict.get("DEPLOYMENT_ENVIRONMENT") == "PRODUCTION"
