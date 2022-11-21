import logging
import yaml


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

            bucket_list = []
            public_ecr_repo_list = []
            private_ecr_repo_list = []
            for key, value in loaded_config.items():
                if "BUCKET_NAME" in key:
                    bucket_list.append(value)
                if "PUBLIC_ECR_NAME" in key:
                    public_ecr_repo_list.append(value)
                if "PRIVATE_ECR_NAME" in key:
                    private_ecr_repo_list.append(value)

                config[key] = value

            # Initialize other constants after loading YAML file
            config["INSTR_TO_BUCKET_NAME"] = [
                f"{config['MISSION_NAME']}-{this_instr}"
                for this_instr in config["INSTR_NAMES"]
            ]
            config["BUCKET_LIST"] = bucket_list + config["INSTR_TO_BUCKET_NAME"]
            config["ECR_PUBLIC_REPO_LIST"] = public_ecr_repo_list
            config["ECR_PRIVATE_REPO_LIST"] = private_ecr_repo_list

    except FileNotFoundError:
        logging.error(
            "config.yaml not found. Check to make sure it exists in the root directory."
        )
        exit(1)

    return config


def validate_config(config):
    """
    This function validates the config dict
    """
    # Check if all required keys are present
    required_keys = [
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

    # Check if all required keys are present return false if not
    for key in required_keys:
        if key not in config:
            logging.error(f"{key} not found in config.yaml")
            return False

    return True
