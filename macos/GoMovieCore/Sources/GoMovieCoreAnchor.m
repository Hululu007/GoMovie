#import "GoMovieCoreAnchor.h"
#include <stddef.h>

extern char *GoMovieRequest(char *input);
extern void GoMovieFree(char *value);

void DjuEnsureCoreLinked(void) {
    char *result = GoMovieRequest(NULL);
    if (result != NULL) {
        GoMovieFree(result);
    }
}
