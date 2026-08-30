Object detection — how to use this desktop
==========================================

Everything happens in this folder. Put an image here (or find one you have
mounted), run the detector on it, and look at the result.

1. Get an image in here
-----------------------
If you started the container with a bind mount, whatever was in that directory
is already here. Otherwise drag a file into the Files window, or fetch one in
the terminal.

2. Run the detector
-------------------
Open Terminal (or the "Object detection" launcher, which opens a terminal that
has already printed the help) and run:

    detect photo.jpg

That writes two files next to the original:

    photo_detected.jpg   the same picture with boxes and labels drawn on it
    detections.json      one record per object: class, confidence, bbox

Useful variations:

    detect --open photo.jpg          run it, then open the result in the viewer
    detect photo.jpg --conf 0.4      keep only detections the model is surer of
    detect --help                    every option

`detect` is a wrapper around /app/run.py, which is the exact program the batch
container app-object-detection runs. Any command that works here works there.

3. Look at the results
----------------------
Open Files. The icon view shows thumbnails, so photo.jpg and
photo_detected.jpg sit side by side and the difference is visible without
opening either.

Double-click either one to open the Image Viewer. It loads the whole folder,
so the left and right arrow keys flip between the original and the annotated
version at the same zoom — which is the comparison worth making.

4. Keeping your results
-----------------------
This home directory lives inside the container unless you bind-mounted it.
Under Docker that means `-v "$PWD:/home/ospuser"`; under Apptainer you are
already in your own directory and nothing is lost.

The model
---------
yolo11n.pt, baked into the image at /app/yolo11n.pt and trained on COCO's 80
everyday classes — people, vehicles, animals, furniture, food. It cannot find
anything outside that list, so a picture with no such objects in it correctly
produces no detections.

Nothing is ever downloaded at run time. This container works with no network
at all, which is the point: the compute nodes it is built for often have none.
