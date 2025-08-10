#!/bin/bash
# Run the all-features container for testing and verification

# Container name for easy reference
CONTAINER_NAME="test-container"

# Remove any existing container with the same name
docker rm -f $CONTAINER_NAME 2>/dev/null || true

echo "Starting all-features container..."
echo "Container name: $CONTAINER_NAME"
echo ""

# Run the container with:
# - Interactive terminal (-it)
# - Remove on exit (--rm)
# - Named container for easy exec access
# - Mount current directory to workspace
# - Mount cache volumes for persistence
# - Keep container running with tail -f /dev/null
docker run -it \
  --name $CONTAINER_NAME \
  --entrypoint /bin/bash \
  -v "$(pwd):/workspace/project" \
  -v "project-cache:/cache" \
  -w /workspace/project \
  test-all-features \
  -c "tail -f /dev/null" &

# Wait a moment for container to start
sleep 2

echo "Container started successfully!"
echo ""
echo "To enter the container:"
echo "  docker exec -it $CONTAINER_NAME bash"
echo ""
echo "To check installed tools:"
echo "  docker exec -it $CONTAINER_NAME /opt/container-runtime/check-installed-versions.sh"
echo ""
echo "To stop the container:"
echo "  docker stop $CONTAINER_NAME"
echo ""
echo "To view container logs:"
echo "  docker logs $CONTAINER_NAME"