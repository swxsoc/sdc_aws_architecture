.. _docker_overview:

Docker Overview
================
Docker is a tool designed to make it easier to create, deploy, and run containers by using OS-level virtualization to deliver software in packages called containers. Containers are isolated from one another and bundle their own software, libraries and configuration files. To learn more on how to set-up and use Docker, please refer to the official documentation at https://docs.docker.com/.

How we make use of Docker
-------------------------
We use two docker images in a few areas in the pipeline:

- For the base image, which is currently used in the devcontainer environments in the mission core and intrument packages. (Which is currently being maintained by HERMES-SOC in a public repository and is used by the processing lambda function as a base image). `Check out the documentation for the SWSOC Base Image <https://sdc-aws-base-docker-image.readthedocs.io/en/latest/>`_.

- For lambda processing function that is built within the pipeline. It utilizes the base image as a foundation and adds the necessary dependencies for the function to work. If you'd like to change the base image it uses you will need to make a change in the `Dockerfile` in the Processing Lambda Function directory.

Learn More
----------
For more information on how to use Docker, please refer to the official documentation at https://docs.docker.com/.