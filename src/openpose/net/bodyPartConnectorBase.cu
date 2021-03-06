#include <openpose/gpu/cuda.hpp>
#include <openpose/pose/poseParameters.hpp>
#include <openpose/utilities/fastMath.hpp>
#include <openpose/net/bodyPartConnectorBase.hpp>

namespace op
{
    template<typename T>
    inline __device__ int intRoundGPU(const T a)
    {
        return int(a+T(0.5));
    }

    template <typename T>
    inline __device__  T process(
        const T* bodyPartA, const T* bodyPartB, const T* mapX, const T* mapY, const int heatmapWidth,
        const int heatmapHeight, const T interThreshold, const T interMinAboveThreshold, const T defaultNmsThreshold,
        const T scale = 1.0)
    {
        const auto vectorAToBX = (bodyPartB[0] - bodyPartA[0])*scale;
        const auto vectorAToBY = (bodyPartB[1] - bodyPartA[1])*scale;
        const auto vectorAToBMax = max(abs(vectorAToBX), abs(vectorAToBY));
        const auto numberPointsInLine = max(5, min(25, intRoundGPU(sqrt(5*vectorAToBMax))));
        const auto vectorNorm = T(sqrt(vectorAToBX*vectorAToBX + vectorAToBY*vectorAToBY));

        if (vectorNorm > 1e-6)
        {
            const auto sX = bodyPartA[0]*scale;
            const auto sY = bodyPartA[1]*scale;
            const auto vectorAToBNormX = vectorAToBX/vectorNorm;
            const auto vectorAToBNormY = vectorAToBY/vectorNorm;

            auto sum = T(0.);
            auto count = 0;
            const auto vectorAToBXInLine = vectorAToBX/numberPointsInLine;
            const auto vectorAToBYInLine = vectorAToBY/numberPointsInLine;
            for (auto lm = 0; lm < numberPointsInLine; lm++)
            {
                const auto mX = min(heatmapWidth-1, intRoundGPU(sX + lm*vectorAToBXInLine));
                const auto mY = min(heatmapHeight-1, intRoundGPU(sY + lm*vectorAToBYInLine));
                const auto idx = mY * heatmapWidth + mX;
                const auto score = (vectorAToBNormX*mapX[idx] + vectorAToBNormY*mapY[idx]);
                if (score > interThreshold)
                {
                    sum += score;
                    count++;
                }
            }

            // Return PAF score
            if (count/T(numberPointsInLine) > interMinAboveThreshold)
                return sum/count;
            else
            {
                // Ideally, if distanceAB = 0, PAF is 0 between A and B, provoking a false negative
                // To fix it, we consider PAF-connected keypoints very close to have a minimum PAF score, such that:
                //     1. It will consider very close keypoints (where the PAF is 0)
                //     2. But it will not automatically connect them (case PAF score = 1), or real PAF might got
                //        missing
                // return -1;
                const auto l2Dist = sqrtf(vectorAToBX*vectorAToBX + vectorAToBY*vectorAToBY);
                const auto threshold = sqrtf(heatmapWidth*heatmapHeight)/150; // 3.3 for 368x656, 6.6 for 2x resolution
                if (l2Dist < threshold)
                    return T(defaultNmsThreshold+1e-6); // Without 1e-6 will not work because I use strict greater
            }
        }
        return -1;
    }

    // template <typename T>
    // __global__ void pafScoreKernelOld(
    //     T* pairScoresPtr, const T* const heatMapPtr, const T* const peaksPtr, const unsigned int* const bodyPartPairsPtr,
    //     const unsigned int* const mapIdxPtr, const unsigned int maxPeaks, const int numberBodyPartPairs,
    //     const int heatmapWidth, const int heatmapHeight, const T interThreshold, const T interMinAboveThreshold,
    //     const T defaultNmsThreshold)
    // {
    //     const auto pairIndex = (blockIdx.x * blockDim.x) + threadIdx.x;
    //     const auto peakA = (blockIdx.y * blockDim.y) + threadIdx.y;
    //     const auto peakB = (blockIdx.z * blockDim.z) + threadIdx.z;

    //     if (pairIndex < numberBodyPartPairs && peakA < maxPeaks && peakB < maxPeaks)
    //     {
    //         const auto baseIndex = 2*pairIndex;
    //         const auto partA = bodyPartPairsPtr[baseIndex];
    //         const auto partB = bodyPartPairsPtr[baseIndex + 1];

    //         const T numberPeaksA = peaksPtr[3*partA*(maxPeaks+1)];
    //         const T numberPeaksB = peaksPtr[3*partB*(maxPeaks+1)];

    //         const auto outputIndex = (pairIndex*maxPeaks+peakA)*maxPeaks + peakB;
    //         if (peakA < numberPeaksA && peakB < numberPeaksB)
    //         {
    //             const auto mapIdxX = mapIdxPtr[baseIndex];
    //             const auto mapIdxY = mapIdxPtr[baseIndex + 1];

    //             const T* const bodyPartA = peaksPtr + (3*(partA*(maxPeaks+1) + peakA+1));
    //             const T* const bodyPartB = peaksPtr + (3*(partB*(maxPeaks+1) + peakB+1));
    //             const T* const mapX = heatMapPtr + mapIdxX*heatmapWidth*heatmapHeight;
    //             const T* const mapY = heatMapPtr + mapIdxY*heatmapWidth*heatmapHeight;
    //             pairScoresPtr[outputIndex] = process(
    //                 bodyPartA, bodyPartB, mapX, mapY, heatmapWidth, heatmapHeight, interThreshold,
    //                 interMinAboveThreshold, defaultNmsThreshold);
    //         }
    //         else
    //             pairScoresPtr[outputIndex] = -1;
    //     }
    // }

    template <typename T>
    __global__ void pafScoreKernel(
        T* pairScoresPtr, const T* const heatMapPtr, const T* const peaksPtr, const unsigned int* const bodyPartPairsPtr,
        const unsigned int* const mapIdxPtr, const unsigned int maxPeaks, const int numberBodyPartPairs,
        const int heatmapWidth, const int heatmapHeight, const T interThreshold, const T interMinAboveThreshold,
        const T defaultNmsThreshold)
    {
        const auto peakB = (blockIdx.x * blockDim.x) + threadIdx.x;
        const auto peakA = (blockIdx.y * blockDim.y) + threadIdx.y;
        const auto pairIndex = (blockIdx.z * blockDim.z) + threadIdx.z;

        if (peakA < maxPeaks && peakB < maxPeaks)
        // if (pairIndex < numberBodyPartPairs && peakA < maxPeaks && peakB < maxPeaks)
        {
            const auto baseIndex = 2*pairIndex;
            const auto partA = bodyPartPairsPtr[baseIndex];
            const auto partB = bodyPartPairsPtr[baseIndex + 1];

            const T numberPeaksA = peaksPtr[3*partA*(maxPeaks+1)];
            const T numberPeaksB = peaksPtr[3*partB*(maxPeaks+1)];

            const auto outputIndex = (pairIndex*maxPeaks+peakA)*maxPeaks + peakB;
            if (peakA < numberPeaksA && peakB < numberPeaksB)
            {
                const auto mapIdxX = mapIdxPtr[baseIndex];
                const auto mapIdxY = mapIdxPtr[baseIndex + 1];

                const T* const bodyPartA = peaksPtr + (3*(partA*(maxPeaks+1) + peakA+1));
                const T* const bodyPartB = peaksPtr + (3*(partB*(maxPeaks+1) + peakB+1));
                const T* const mapX = heatMapPtr + mapIdxX*heatmapWidth*heatmapHeight;
                const T* const mapY = heatMapPtr + mapIdxY*heatmapWidth*heatmapHeight;
                pairScoresPtr[outputIndex] = process(
                    bodyPartA, bodyPartB, mapX, mapY, heatmapWidth, heatmapHeight, interThreshold,
                    interMinAboveThreshold, defaultNmsThreshold);
            }
            else
                pairScoresPtr[outputIndex] = -1;
        }
    }

    template <typename T>
    __global__ void tafScoreKernel(T* tafScoresPtr, const T* const heatMapPtr, const T* const posePtr,
                                   const T* const trackletPtr, const int* const tafPartPairsPtr,
                                   const int totalPose, const int totalTracklet,
                                   const int numberBodyParts, const int tafHeatmapOffset,
                                   const int heatmapWidth, const int heatmapHeight, const T interThreshold,
                                   const T interMinAboveThreshold, const T scale)
    {
        const auto pairIndex = (blockIdx.x * blockDim.x) + threadIdx.x;
        const auto pid = (blockIdx.y * blockDim.y) + threadIdx.y;
        const auto tid = (blockIdx.z * blockDim.z) + threadIdx.z;

        if(pid >= totalPose || tid >= totalTracklet) return;

        const auto partA = tafPartPairsPtr[pairIndex*2 + 0];
        const auto partB = tafPartPairsPtr[pairIndex*2 + 1];

        const T* tafMapPtr = heatMapPtr + tafHeatmapOffset*(heatmapWidth*heatmapHeight);
        const T* mapX = tafMapPtr + (2*pairIndex + 0)*(heatmapWidth*heatmapHeight);
        const T* mapY = tafMapPtr + (2*pairIndex + 1)*(heatmapWidth*heatmapHeight);

        const T* bodyPartA = posePtr + (pid * numberBodyParts * 3) + (partA * 3);
        const T* bodyPartB = trackletPtr + (tid * numberBodyParts * 3) + (partB * 3);

        const auto outputIndex = (pairIndex*totalPose*totalTracklet) + (pid*totalTracklet) + tid;

        if(bodyPartA[2] < interThreshold || bodyPartB[2] < interThreshold){
            tafScoresPtr[outputIndex] = -1;
        }else{
            tafScoresPtr[outputIndex] = process(
                bodyPartB, bodyPartA, mapX, mapY, heatmapWidth, heatmapHeight, interThreshold,
                interMinAboveThreshold, (T)0.05, scale);
        }
    }

    template <typename T>
    void tafScoreGPU(const op::Array<T>& poseKeypoints, const op::Array<T>& trackletKeypoints,
                     const std::shared_ptr<ArrayCpuGpu<T>> heatMapsBlob, op::Array<T>& tafScores,
                     const std::vector<int> tafPartPairs, int* &tafPartPairsGpuPtr, int tafChannelStart, T scale)
    {
        try
        {
            // Copy both to GPU
            T* poseGpuPtr;
            T* trackletGpuPtr;
            cudaMalloc((void **)&poseGpuPtr, poseKeypoints.getVolume() * sizeof(T));
            cudaMemcpy(poseGpuPtr, poseKeypoints.getConstPtr(), poseKeypoints.getVolume() * sizeof(T),
                       cudaMemcpyHostToDevice);
            cudaMalloc((void **)&trackletGpuPtr, trackletKeypoints.getVolume() * sizeof(T));
            cudaMemcpy(trackletGpuPtr, trackletKeypoints.getConstPtr(), trackletKeypoints.getVolume() * sizeof(T),
                       cudaMemcpyHostToDevice);

            // Score Data
            int totalPairs = (tafPartPairs.size()/2);
            int totalPosePeople = poseKeypoints.getSize(0);
            int totalTrackletPeople = trackletKeypoints.getSize(0);
            int totalComputations = totalPairs * totalPosePeople * totalTrackletPeople;
            T* tafScoreGpuPtr;
            cudaMalloc((void **)&tafScoreGpuPtr, totalComputations * sizeof(T));

            // Kernel
            const T* heatMapPtr = (T*)heatMapsBlob->gpu_data();
            //const T* heatMapPtr = nullptr;
            int totalBodyParts = poseKeypoints.getSize(1);
            T interThreshold = 0.05;
            T interMinAboveThreshold = 0.95;
            const dim3 THREADS_PER_BLOCK{4, 16, 16};
            const dim3 numBlocks{
                op::getNumberCudaBlocks(totalPairs, THREADS_PER_BLOCK.x),
                op::getNumberCudaBlocks(op::POSE_MAX_PEOPLE, THREADS_PER_BLOCK.y),
                op::getNumberCudaBlocks(op::TRACK_MAX_PEOPLE, THREADS_PER_BLOCK.z)};

            // Call Kernel
            tafScoreKernel<<<numBlocks, THREADS_PER_BLOCK>>>(
                tafScoreGpuPtr, heatMapPtr, poseGpuPtr, trackletGpuPtr, tafPartPairsGpuPtr,
                totalPosePeople, totalTrackletPeople,
                totalBodyParts, tafChannelStart, (int)heatMapsBlob->shape(3), (int)heatMapsBlob->shape(2), interThreshold, interMinAboveThreshold, scale);

            // Get Data
            tafScores.reset({totalPairs, totalPosePeople, totalTrackletPeople});
            cudaMemcpy(tafScores.getPtr(), tafScoreGpuPtr, totalComputations * sizeof(T),
                       cudaMemcpyDeviceToHost);

            // Free memory (Better way to do this?)
            cudaFree(tafScoreGpuPtr);
            cudaFree(poseGpuPtr);
            cudaFree(trackletGpuPtr);
        }
        catch (const std::exception& e)
        {
            error(e.what(), __LINE__, __FUNCTION__, __FILE__);
        }
    }

    template <typename T>
    void connectBodyPartsGpu(
        Array<T>& poseKeypoints, Array<T>& poseScores, const T* const heatMapGpuPtr, const T* const peaksPtr,
        const PoseModel poseModel, const Point<int>& heatMapSize, const int maxPeaks, const T interMinAboveThreshold,
        const T interThreshold, const int minSubsetCnt, const T minSubsetScore, const T scaleFactor,
        const bool maximizePositives, Array<T> pairScoresCpu, T* pairScoresGpuPtr,
        const unsigned int* const bodyPartPairsGpuPtr, const unsigned int* const mapIdxGpuPtr,
        const T* const peaksGpuPtr, const T defaultNmsThreshold)
    {
        try
        {
            // Parts Connection
            const auto& bodyPartPairs = getPosePartPairs(poseModel);
            const auto numberBodyParts = getPoseNumberBodyParts(poseModel);
            const auto numberBodyPartPairs = (unsigned int)(bodyPartPairs.size() / 2);
            const auto totalComputations = pairScoresCpu.getVolume();

            if (numberBodyParts == 0)
                error("Invalid value of numberBodyParts, it must be positive, not " + std::to_string(numberBodyParts),
                      __LINE__, __FUNCTION__, __FILE__);
            if (bodyPartPairsGpuPtr == nullptr || mapIdxGpuPtr == nullptr)
                error("The pointers bodyPartPairsGpuPtr and mapIdxGpuPtr cannot be nullptr.",
                      __LINE__, __FUNCTION__, __FILE__);

            // const auto REPS = 1000;
            // double timeNormalize0 = 0.;
            // double timeNormalize1 = 0.;
            // double timeNormalize2 = 0.;

            // // Old - Non-efficient code
            // OP_CUDA_PROFILE_INIT(REPS);
            // // Run Kernel - pairScoresGpu
            // const dim3 THREADS_PER_BLOCK{4, 16, 16};
            // const dim3 numBlocks{
            //     getNumberCudaBlocks(numberBodyPartPairs, THREADS_PER_BLOCK.x),
            //     getNumberCudaBlocks(maxPeaks, THREADS_PER_BLOCK.y),
            //     getNumberCudaBlocks(maxPeaks, THREADS_PER_BLOCK.z)};
            // pafScoreKernelOld<<<numBlocks, THREADS_PER_BLOCK>>>(
            //     pairScoresGpuPtr, heatMapGpuPtr, peaksGpuPtr, bodyPartPairsGpuPtr, mapIdxGpuPtr,
            //     maxPeaks, (int)numberBodyPartPairs, heatMapSize.x, heatMapSize.y, interThreshold,
            //     interMinAboveThreshold, defaultNmsThreshold);
            // // pairScoresCpu <-- pairScoresGpu
            // cudaMemcpy(pairScoresCpu.getPtr(), pairScoresGpuPtr, totalComputations * sizeof(T),
            //            cudaMemcpyDeviceToHost);
            // OP_PROFILE_END(timeNormalize1, 1e3, REPS);

            // Efficient code
            // OP_CUDA_PROFILE_INIT(REPS);
            // Run Kernel - pairScoresGpu
            const dim3 THREADS_PER_BLOCK{128, 1, 1};
            const dim3 numBlocks{
                getNumberCudaBlocks(maxPeaks, THREADS_PER_BLOCK.x),
                getNumberCudaBlocks(maxPeaks, THREADS_PER_BLOCK.y),
                getNumberCudaBlocks(numberBodyPartPairs, THREADS_PER_BLOCK.z)};
            pafScoreKernel<<<numBlocks, THREADS_PER_BLOCK>>>(
                pairScoresGpuPtr, heatMapGpuPtr, peaksGpuPtr, bodyPartPairsGpuPtr, mapIdxGpuPtr,
                maxPeaks, (int)numberBodyPartPairs, heatMapSize.x, heatMapSize.y, interThreshold,
                interMinAboveThreshold, defaultNmsThreshold);
            // pairScoresCpu <-- pairScoresGpu
            cudaMemcpy(pairScoresCpu.getPtr(), pairScoresGpuPtr, totalComputations * sizeof(T),
                       cudaMemcpyDeviceToHost);
            // OP_PROFILE_END(timeNormalize2, 1e3, REPS);

            // Get pair connections and their scores
            const auto pairConnections = pafPtrIntoVector(
                pairScoresCpu, peaksPtr, maxPeaks, bodyPartPairs, numberBodyPartPairs);
            auto peopleVector = pafVectorIntoPeopleVector(
                pairConnections, peaksPtr, maxPeaks, bodyPartPairs, numberBodyParts);
            // // Old code: Get pair connections and their scores
            // // std::vector<std::pair<std::vector<int>, double>> refers to:
            // //     - std::vector<int>: [body parts locations, #body parts found]
            // //     - double: person subset score
            // const T* const tNullptr = nullptr;
            // const auto peopleVector = createPeopleVector(
            //     tNullptr, peaksPtr, poseModel, heatMapSize, maxPeaks, interThreshold, interMinAboveThreshold,
            //     bodyPartPairs, numberBodyParts, numberBodyPartPairs, pairScoresCpu);
            // Delete people below the following thresholds:
                // a) minSubsetCnt: removed if less than minSubsetCnt body parts
                // b) minSubsetScore: removed if global score smaller than this
                // c) maxPeaks (POSE_MAX_PEOPLE): keep first maxPeaks people above thresholds
            int numberPeople;
            std::vector<int> validSubsetIndexes;
            // validSubsetIndexes.reserve(fastMin((size_t)maxPeaks, peopleVector.size()));
            validSubsetIndexes.reserve(peopleVector.size());
            removePeopleBelowThresholdsAndFillFaces(
                validSubsetIndexes, numberPeople, peopleVector, numberBodyParts, minSubsetCnt, minSubsetScore,
                maximizePositives, peaksPtr);
            // Fill and return poseKeypoints
            peopleVectorToPeopleArray(
                poseKeypoints, poseScores, scaleFactor, peopleVector, validSubsetIndexes, peaksPtr, numberPeople,
                numberBodyParts, numberBodyPartPairs);

            // // Profiling verbose
            // log("  BPC(ori)=" + std::to_string(timeNormalize1) + "ms");
            // log("  BPC(new)=" + std::to_string(timeNormalize2) + "ms");

            // Sanity check
            cudaCheck(__LINE__, __FUNCTION__, __FILE__);
        }
        catch (const std::exception& e)
        {
            error(e.what(), __LINE__, __FUNCTION__, __FILE__);
        }
    }

    template void connectBodyPartsGpu(
        Array<float>& poseKeypoints, Array<float>& poseScores, const float* const heatMapGpuPtr,
        const float* const peaksPtr, const PoseModel poseModel, const Point<int>& heatMapSize, const int maxPeaks,
        const float interMinAboveThreshold, const float interThreshold, const int minSubsetCnt,
        const float minSubsetScore, const float scaleFactor, const bool maximizePositives,
        Array<float> pairScoresCpu, float* pairScoresGpuPtr, const unsigned int* const bodyPartPairsGpuPtr,
        const unsigned int* const mapIdxGpuPtr, const float* const peaksGpuPtr, const float defaultNmsThreshold);
    template void connectBodyPartsGpu(
        Array<double>& poseKeypoints, Array<double>& poseScores, const double* const heatMapGpuPtr,
        const double* const peaksPtr, const PoseModel poseModel, const Point<int>& heatMapSize, const int maxPeaks,
        const double interMinAboveThreshold, const double interThreshold, const int minSubsetCnt,
        const double minSubsetScore, const double scaleFactor, const bool maximizePositives,
        Array<double> pairScoresCpu, double* pairScoresGpuPtr, const unsigned int* const bodyPartPairsGpuPtr,
        const unsigned int* const mapIdxGpuPtr, const double* const peaksGpuPtr, const double defaultNmsThreshold);

    template void tafScoreGPU(const op::Array<float>& poseKeypoints, const op::Array<float>& trackletKeypoints,
        const std::shared_ptr<ArrayCpuGpu<float>> heatMapsBlob, op::Array<float>& tafScores,
        const std::vector<int> tafPartPairs, int* &tafPartPairsGpuPtr, int tafChannelStart, float scale);
    template void tafScoreGPU(const op::Array<double>& poseKeypoints, const op::Array<double>& trackletKeypoints,
        const std::shared_ptr<ArrayCpuGpu<double>> heatMapsBlob, op::Array<double>& tafScores,
        const std::vector<int> tafPartPairs, int* &tafPartPairsGpuPtr, int tafChannelStart, double scale);
}
