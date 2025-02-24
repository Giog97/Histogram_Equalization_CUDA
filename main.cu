//
// Created by gioste.
//

#include <iostream>
#include <opencv2/opencv.hpp>
#include <filesystem>
#include <vector>
#include <chrono> // Libreria per il timing
#include "histogram_equalization_cuda.h"
#include "histogram_equalization_seq.h"

using namespace cv;
using namespace std;
namespace fs = std::filesystem;

// Funzione per ritrasformare un'immagine equalizzata in scala di grigi in RGB
Mat restoreColorImage(const Mat& original, const Mat& equalized_gray) {
    // Converti l'immagine originale in YCrCb
    Mat ycrcb;
    cvtColor(original, ycrcb, COLOR_BGR2YCrCb);

    // Separa i canali Y, Cr, Cb
    vector<Mat> channels;
    split(ycrcb, channels);

    // Sostituisci il canale Y (luminanza) con l'immagine equalizzata
    channels[0] = equalized_gray;

    // Unisci i canali Y, Cr, Cb di nuovo in un'immagine YCrCb
    merge(channels, ycrcb);

    // Converti di nuovo in BGR (RGB in OpenCV)
    Mat result;
    cvtColor(ycrcb, result, COLOR_YCrCb2BGR);

    return result;
}

int main() {
    string img_dir = "img";  // Nome della cartella con le immagini
    string result_dir = "img_results";  // Nome della cartella per i risultati

    cv::utils::logging::setLogLevel(cv::utils::logging::LOG_LEVEL_WARNING); // Serve per avere un output più leggibile (sennò OpenCV manda dei log in output)

    // Verifica se la cartella delle immagini esiste
    if (!fs::exists(img_dir) || !fs::is_directory(img_dir)) {
        cerr << "Errore: la cartella '" << img_dir << "' non esiste!" << endl;
        return -1;
    }

    // Crea la cartella per i risultati se non esiste
    if (!fs::exists(result_dir)) {
        fs::create_directory(result_dir);
    }

    // Lista dei file disponibili nella cartella
    vector<string> images;
    for (const auto& entry : fs::directory_iterator(img_dir)) {
        if (entry.is_regular_file()) {
            images.push_back(entry.path().string());
        }
    }

    // Se non ci sono immagini, uscire
    if (images.empty()) {
        cerr << "Errore: nessuna immagine trovata nella cartella '" << img_dir << "'!" << endl;
        return -1;
    }

    // Mostra la lista di immagini disponibili
    cout << "Scegli un'immagine da equalizzare:\n";
    for (size_t i = 0; i < images.size(); ++i) {
        cout << i + 1 << ") " << images[i] << endl;
    }

    // Scegli un numero
    size_t choice;
    cout << "Inserisci il numero dell'immagine: ";
    cin >> choice;

    if (choice < 1 || choice > images.size()) {
        cerr << "Errore: scelta non valida!" << endl;
        return -1;
    }

    string selected_image = images[choice - 1];

    // Carica l'immagine
    Mat input = imread(selected_image, IMREAD_COLOR);
    if (input.empty()) {
        cout << "Errore: impossibile caricare l'immagine!" << endl;
        return -1;
    }

    // Converti l'immagine in scala di grigi
    Mat input_gray;
    cvtColor(input, input_gray, COLOR_BGR2GRAY); // Questo è indispensabile per versione CUDA, mentre per la sequenziale ha un controllo al suo interno

    // Informazioni utili per il calcolo dell'Occupancy
    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, 0);
    printf("GPU: %s\n", prop.name);
    printf("Compute Capability: %d.%d\n", prop.major, prop.minor);
    printf("SMs: %d\n", prop.multiProcessorCount);
    // printf("Warp size: %d\n", prop.warpSize); // è sempre 32 il max dim del warp
    // printf("Max threads per block: %d\n", prop.maxThreadsPerBlock); // La max dimensione per i blocci è sempre 1024
    printf("Registers per block: %d\n", prop.regsPerBlock);
    printf("Shared memory per block: %lu bytes\n", prop.sharedMemPerBlock);
    printf("Threads per SM: %d\n", prop.maxThreadsPerMultiProcessor);
    //std::cout << "CUDA Compiler Version: " << __CUDACC_VER_MAJOR__ << "."
    //          << __CUDACC_VER_MINOR__ << "." << __CUDACC_VER_BUILD__ << std::endl; // Restituisce la versione del compilatore nvcc usata
    // std::cout << "Host Compiler: MSVC " << _MSC_VER << std::endl; // Compilatore usato da me è MSVC

    // Inizializza output sequenziale
    Mat output_seq;

    // Inizializza output_cuda con le stesse dimensioni e tipo di input_gray
    Mat output_cuda = Mat::zeros(input_gray.size(), input_gray.type());

    // --- MISURAZIONE TEMPO DI ESECUZIONE SEQUENZIALE (uso std:chrono) ---
    auto start_seq = chrono::high_resolution_clock::now(); // Tempo iniziale
    histogram_equalization_seq(input_gray, output_seq);
    auto end_seq = chrono::high_resolution_clock::now(); // Tempo finale
    chrono::duration<double, milli> elapsed_seq = end_seq - start_seq;  // Calcola differenza in millisecondi

    cout << "--> Tempo di esecuzione dell'algoritmo sequenziale: " << elapsed_seq.count() << " ms" << endl;

    // --- MISURAZIONE TEMPO DI ESECUZIONE CUDA (uso std:chrono) ---
    auto start_cuda = chrono::high_resolution_clock::now(); // Tempo iniziale
    histogram_equalization_cuda(input_gray, output_cuda);
    auto end_cuda = chrono::high_resolution_clock::now(); // Tempo finale
    chrono::duration<double, milli> elapsed_cuda = end_cuda - start_cuda; // Calcola differenza in millisecondi

    cout << "--> Tempo di esecuzione CUDA (kernel + overhead di comunicazione tra CPU e GPU): " << elapsed_cuda.count() << " ms" << endl;

    // Dopo l'equalizzazione (sequenziale o CUDA), ripristina le immagini a colori (sennò sarebbero grige) per visualizzare bene il risultato
    Mat output_seq_color = restoreColorImage(input, output_seq);
    Mat output_cuda_color = restoreColorImage(input, output_cuda);

    // Definizione delle sottocartelle
    string gray_dir = result_dir + "/gray";
    string color_dir = result_dir + "/color";

    // Crea le sottocartelle se non esistono
    if (!fs::exists(gray_dir)) {
        fs::create_directory(gray_dir);
    }
    if (!fs::exists(color_dir)) {
        fs::create_directory(color_dir);
    }

    // Salvataggio delle immagini in scala di grigi
    string output_path_seq = gray_dir + "/equalized_seq_" + fs::path(selected_image).filename().string();
    string output_path_cuda = gray_dir + "/equalized_cuda_" + fs::path(selected_image).filename().string();
    imwrite(output_path_seq, output_seq);
    imwrite(output_path_cuda, output_cuda);

    //cout << "Immagine sequenziale salvata come: " << output_path_seq << endl;
    //cout << "Immagine CUDA salvata come: " << output_path_cuda << endl;

    // Salvataggio delle immagini a colori
    string output_path_seq_color = color_dir + "/equalized_seq_color_" + fs::path(selected_image).filename().string();
    string output_path_cuda_color = color_dir + "/equalized_cuda_color_" + fs::path(selected_image).filename().string();
    imwrite(output_path_seq_color, output_seq_color);
    imwrite(output_path_cuda_color, output_cuda_color);

    //cout << "Immagine sequenziale a colori salvata come: " << output_path_seq_color << endl;
    //cout << "Immagine CUDA a colori salvata come: " << output_path_cuda_color << endl;

    // Si ottiene sia immagini in grigio che immagini a colori equalizzate.
    // Così da quelle in grigio posso ottenere gli istogrammi da python per il report.
    // Mentre da quelle a colori posso vedere il vero effetto della equalizzazione.

    return 0;
}




