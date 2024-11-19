# Using the PgVector PostgreSQL extension in Perl

Perl is a high-level, general-purpose, interpreted, dynamic programming
language. It is widely used in web development, network programming, GUI
development, and more. Perl is known for its powerful text processing features
and is used for many system administration tasks.

However, often we want to search data for the _meaning_ of the data, not just
the text. For example, we might want to search for "dog" and find "puppy" or
"canine" as well. This is where the PgVector extension for PostgreSQL comes in.

# Setup

First, you need to install the PgVector extension. You can find the project
[on github](https://github.com/pgvector/pgvector). You can install the
extension directly, but for the purposes of this example, we will use a Docker
container.

```bash
# Stop and remove existing container (if any)
docker rm -f pgvector-db

# Build fresh image if needed
docker build -t pgvector .

# Run with database creation
docker run -d --name pgvector-db  \
   -e POSTGRES_PASSWORD=mysecretpassword \
   -p 55431:5431 pgvector

# Create database
docker exec -it pgvector-db createdb -U postgres pgvector_perl_test
```

If all does well, you can run the following:

```bash
docker exec -it pgvector-db psql -U postgres -d pgvector_perl_test -c "SELECT 'PostgreSQL available'"
```

That should return `PostgreSQL available`.

Note that the ports and passwords are set to very specific values to allow
this demo to work. In a production environment, you would want to use more
secure/robust settings.

# OpenAI

In order to use PgVector, you need to have a source of "embeddings". These are
vectors that represent the meaning of words. Sadly, Perl doesn't have a good
library for this, so we will use OpenAI's embeddings API.

To use this module, you’ll need an API key from OpenAI. Visit [OpenAI’s
platform website](https://platform.openai.com/docs/overview). You’ll need to
sign up or log in to that page.

Once logged in, click on your profile icon at the top-right corner of the page.
Select “Your profile” and then click on the “User API Keys” tab. As of this
writing, it will have a useful message saying “User API keys have been replaced
by project API keys,” so you need to click on the “View project API keys”
button.

On the Project API Keys page, click “Create new secret key” and give it a
memorable name. You won’t be able to see that key again, so you’ll need to copy

The key needs to be stored in the OPENAI_API_KEY environment variable. For
Linux/Mac users the following line in whichever “rc” or “profile” file is
appropriate for your system:

```bash
export OPENAI_API_KEY=sk-proj-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

If you don't want to use OpenAI for the embeddings, you might want to write a
small microservice in a language that has good support for embeddings, such as
Python or Node.js. Having that run on a box with a GPU is recommended.

If you go this route, be sure that when trying this code, you adjust the
embedding size to match the size of the embeddings you are using.

```perl
use AI::Vector::PgVector;
my $pgvector = AI::Vector::PgVector->new(
    embedding_size => 2024,
);
$pgvector->build_db; # or -> rebuild_db if you're already built it
```

# Using PgVector in Perl

Most of our code is in the `lib` directory. You can use the following simple
script as an example of _semantic_ querying of the data.

This code requires Perl version 5.40.0 or higher. You can install the
dependencies with `cpanm --installdeps .`.

```perl
#!/usr/bin/env perl

use v5.40.0;
use lib 'lib';
use AI::Vector::PgVector;
use DDP;

my $pgvector = AI::Vector::PgVector->new;

$pgvector->build_db;
my $results = $pgvector->query( 'books about ghosts', 1.3 );
foreach my $book ( $results->@* ) {
    say $book->to_string;
    say '----';
}
```
